-- This file is part of the Wire Server implementation.
--
-- Copyright (C) 2022 Wire Swiss GmbH <opensource@wire.com>
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU Affero General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option) any
-- later version.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
-- FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
-- details.
--
-- You should have received a copy of the GNU Affero General Public License along
-- with this program. If not, see <https://www.gnu.org/licenses/>.

module Wire.API.OAuth where

import Cassandra hiding (Set)
import Control.Lens (preview, view)
import Control.Monad.Except
import Crypto.JWT hiding (Context, params, uri, verify)
import qualified Data.Aeson.KeyMap as M
import qualified Data.Aeson.Types as A
import Data.ByteString.Conversion
import Data.ByteString.Lazy (toStrict)
import qualified Data.HashMap.Strict as HM
import Data.Id as Id
import Data.Range
import Data.Schema
import qualified Data.Set as Set
import Data.String.Conversions (cs)
import qualified Data.Swagger as S
import qualified Data.Text as T
import Data.Text.Ascii
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error as TErr
import Data.Time (NominalDiffTime)
import Imports hiding (exp, head)
import Servant hiding (Handler, JSON, Tagged, addHeader, respond)
import Servant.Swagger.Internal.Orphans ()
import URI.ByteString
import Web.FormUrlEncoded (Form (..), FromForm (..), ToForm (..), parseUnique)
import Wire.API.Error

--------------------------------------------------------------------------------
-- Types

newtype RedirectUrl = RedirectUrl {unRedirectUrl :: URIRef Absolute}
  deriving (Eq, Show, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via (Schema RedirectUrl)

instance ToByteString RedirectUrl where
  builder = serializeURIRef . unRedirectUrl

instance FromByteString RedirectUrl where
  parser = RedirectUrl <$> uriParser strictURIParserOptions

instance ToSchema RedirectUrl where
  schema =
    (TE.decodeUtf8 . serializeURIRef' . unRedirectUrl)
      .= (RedirectUrl <$> parsedText "RedirectUrl" (runParser (uriParser strictURIParserOptions) . TE.encodeUtf8))

instance ToHttpApiData RedirectUrl where
  toUrlPiece = TE.decodeUtf8With TErr.lenientDecode . toHeader
  toHeader = serializeURIRef' . unRedirectUrl

instance FromHttpApiData RedirectUrl where
  parseUrlPiece = parseHeader . TE.encodeUtf8
  parseHeader = bimap (T.pack . show) RedirectUrl . parseURI strictURIParserOptions

newtype OAuthApplicationName = OAuthApplicationName {unOAuthApplicationName :: Range 1 256 Text}
  deriving (Eq, Show, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via (Schema OAuthApplicationName)

instance ToSchema OAuthApplicationName where
  schema = OAuthApplicationName <$> unOAuthApplicationName .= schema

data NewOAuthClient = NewOAuthClient
  { nocApplicationName :: OAuthApplicationName,
    nocRedirectUrl :: RedirectUrl
  }
  deriving (Eq, Show, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via (Schema NewOAuthClient)

instance ToSchema NewOAuthClient where
  schema =
    object "NewOAuthClient" $
      NewOAuthClient
        <$> nocApplicationName .= field "applicationName" schema
        <*> nocRedirectUrl .= field "redirectUrl" schema

newtype OAuthClientPlainTextSecret = OAuthClientPlainTextSecret {unOAuthClientPlainTextSecret :: AsciiBase16}
  deriving (Eq, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via (Schema OAuthClientPlainTextSecret)

instance Show OAuthClientPlainTextSecret where
  show _ = "<OAuthClientPlainTextSecret>"

instance ToSchema OAuthClientPlainTextSecret where
  schema = (toText . unOAuthClientPlainTextSecret) .= parsedText "OAuthClientPlainTextSecret" (fmap OAuthClientPlainTextSecret . validateBase16)

instance FromHttpApiData OAuthClientPlainTextSecret where
  parseQueryParam = bimap cs OAuthClientPlainTextSecret . validateBase16 . cs

instance ToHttpApiData OAuthClientPlainTextSecret where
  toQueryParam = toText . unOAuthClientPlainTextSecret

data OAuthClientCredentials = OAuthClientCredentials
  { occClientId :: OAuthClientId,
    occClientSecret :: OAuthClientPlainTextSecret
  }
  deriving (Eq, Show, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via (Schema OAuthClientCredentials)

instance ToSchema OAuthClientCredentials where
  schema =
    object "OAuthClientCredentials" $
      OAuthClientCredentials
        <$> occClientId .= field "clientId" schema
        <*> occClientSecret .= field "clientSecret" schema

data OAuthClient = OAuthClient
  { ocId :: OAuthClientId,
    ocName :: OAuthApplicationName,
    ocRedirectUrl :: RedirectUrl
  }
  deriving (Eq, Show, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via (Schema OAuthClient)

instance ToSchema OAuthClient where
  schema =
    object "OAuthClient" $
      OAuthClient
        <$> ocId .= field "clientId" schema
        <*> ocName .= field "applicationName" schema
        <*> ocRedirectUrl .= field "redirectUrl" schema

data OAuthResponseType = OAuthResponseTypeCode
  deriving (Eq, Show, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via (Schema OAuthResponseType)

instance ToSchema OAuthResponseType where
  schema :: ValueSchema NamedSwaggerDoc OAuthResponseType
  schema =
    enum @Text "OAuthResponseType" $
      mconcat
        [ element "code" OAuthResponseTypeCode
        ]

data OAuthScope
  = ConversationCreate
  | ConversationCodeCreate
  | SelfRead
  deriving (Eq, Show, Generic, Ord)

class IsOAuthScope scope where
  toOAuthScope :: OAuthScope

instance IsOAuthScope 'ConversationCreate where
  toOAuthScope = ConversationCreate

instance IsOAuthScope 'ConversationCodeCreate where
  toOAuthScope = ConversationCodeCreate

instance IsOAuthScope 'SelfRead where
  toOAuthScope = SelfRead

instance ToByteString OAuthScope where
  builder = \case
    ConversationCreate -> "conversation:create"
    ConversationCodeCreate -> "conversation-code:create"
    SelfRead -> "self:read"

instance FromByteString OAuthScope where
  parser = do
    s <- parser
    case s & T.toLower of
      "conversation:create" -> pure ConversationCreate
      "conversation-code:create" -> pure ConversationCodeCreate
      "self:read" -> pure SelfRead
      _ -> fail "invalid scope"

newtype OAuthScopes = OAuthScopes {unOAuthScopes :: Set OAuthScope}
  deriving (Eq, Show, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via (Schema OAuthScopes)

instance ToSchema OAuthScopes where
  schema = OAuthScopes <$> (oauthScopesToText . unOAuthScopes) .= withParser schema oauthScopeParser

oauthScopesToText :: Set OAuthScope -> Text
oauthScopesToText = T.intercalate " " . fmap (cs . toByteString') . Set.toList

oauthScopeParser :: Text -> A.Parser (Set OAuthScope)
oauthScopeParser "" = pure Set.empty
oauthScopeParser scope =
  pure $ (not . T.null) `filter` T.splitOn " " scope & maybe Set.empty Set.fromList . mapM (fromByteString' . cs)

data NewOAuthAuthCode = NewOAuthAuthCode
  { noacClientId :: OAuthClientId,
    noacScope :: OAuthScopes,
    noacResponseType :: OAuthResponseType,
    noacRedirectUri :: RedirectUrl,
    noacState :: Text
  }
  deriving (Eq, Show, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via (Schema NewOAuthAuthCode)

instance ToSchema NewOAuthAuthCode where
  schema =
    object "NewOAuthAuthCode" $
      NewOAuthAuthCode
        <$> noacClientId .= field "clientId" schema
        <*> noacScope .= field "scope" schema
        <*> noacResponseType .= field "responseType" schema
        <*> noacRedirectUri .= field "redirectUri" schema
        <*> noacState .= field "state" schema

newtype OAuthAuthCode = OAuthAuthCode {unOAuthAuthCode :: AsciiBase16}
  deriving (Show, Eq, Generic)

instance ToSchema OAuthAuthCode where
  schema = (toText . unOAuthAuthCode) .= parsedText "OAuthAuthCode" (fmap OAuthAuthCode . validateBase16)

instance ToByteString OAuthAuthCode where
  builder = builder . unOAuthAuthCode

instance FromByteString OAuthAuthCode where
  parser = OAuthAuthCode <$> parser

instance FromHttpApiData OAuthAuthCode where
  parseQueryParam = bimap cs OAuthAuthCode . validateBase16 . cs

instance ToHttpApiData OAuthAuthCode where
  toQueryParam = toText . unOAuthAuthCode

data OAuthGrantType = OAuthGrantTypeAuthorizationCode
  deriving (Eq, Show, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via (Schema OAuthGrantType)

instance ToSchema OAuthGrantType where
  schema =
    enum @Text "OAuthGrantType" $
      mconcat
        [ element "authorization_code" OAuthGrantTypeAuthorizationCode
        ]

instance FromByteString OAuthGrantType where
  parser = do
    s <- parser
    case s & T.toLower of
      "authorization_code" -> pure OAuthGrantTypeAuthorizationCode
      _ -> fail "invalid OAuthGrantType"

instance ToByteString OAuthGrantType where
  builder = \case
    OAuthGrantTypeAuthorizationCode -> "authorization_code"

instance FromHttpApiData OAuthGrantType where
  parseQueryParam = maybe (Left "invalid OAuthGrantType") pure . fromByteString . cs

instance ToHttpApiData OAuthGrantType where
  toQueryParam = cs . toByteString

data OAuthAccessTokenRequest = OAuthAccessTokenRequest
  { oatGrantType :: OAuthGrantType,
    oatClientId :: OAuthClientId,
    oatClientSecret :: OAuthClientPlainTextSecret,
    oatCode :: OAuthAuthCode,
    oatRedirectUri :: RedirectUrl
  }
  deriving (Eq, Show, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via (Schema OAuthAccessTokenRequest)

instance ToSchema OAuthAccessTokenRequest where
  schema =
    object "OAuthAccessTokenRequest" $
      OAuthAccessTokenRequest
        <$> oatGrantType .= field "grantType" schema
        <*> oatClientId .= field "clientId" schema
        <*> oatClientSecret .= field "clientSecret" schema
        <*> oatCode .= field "code" schema
        <*> oatRedirectUri .= field "redirectUri" schema

instance FromForm OAuthAccessTokenRequest where
  fromForm f =
    OAuthAccessTokenRequest
      <$> parseUnique "grant_type" f
      <*> parseUnique "client_id" f
      <*> parseUnique "client_secret" f
      <*> parseUnique "code" f
      <*> parseUnique "redirect_uri" f

instance ToForm OAuthAccessTokenRequest where
  toForm req =
    Form $
      mempty
        & HM.insert "grant_type" [toQueryParam (oatGrantType req)]
        & HM.insert "client_id" [toQueryParam (oatClientId req)]
        & HM.insert "client_secret" [toQueryParam (oatClientSecret req)]
        & HM.insert "code" [toQueryParam (oatCode req)]
        & HM.insert "redirect_uri" [toQueryParam (oatRedirectUri req)]

data OAuthAccessTokenType = OAuthAccessTokenTypeBearer
  deriving (Eq, Show, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via (Schema OAuthAccessTokenType)

instance ToSchema OAuthAccessTokenType where
  schema =
    enum @Text "OAuthAccessTokenType" $
      mconcat
        [ element "Bearer" OAuthAccessTokenTypeBearer
        ]

newtype OAuthAccessToken = OAuthAccessToken {unOAuthAccessToken :: SignedJWT}
  deriving (Show, Eq, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via Schema OAuthAccessToken

instance ToByteString OAuthAccessToken where
  builder = builder . encodeCompact . unOAuthAccessToken

instance FromByteString OAuthAccessToken where
  parser = do
    t <- parser @Text
    case decodeCompact (cs (TE.encodeUtf8 t)) of
      Left (err :: JWTError) -> fail $ show err
      Right jwt -> pure $ OAuthAccessToken jwt

instance ToHttpApiData OAuthAccessToken where
  toHeader = toByteString'
  toUrlPiece = cs . toHeader

instance FromHttpApiData OAuthAccessToken where
  parseHeader = either (Left . cs) pure . runParser parser . cs
  parseUrlPiece = parseHeader . cs

instance ToSchema OAuthAccessToken where
  schema = (TE.decodeUtf8 . toByteString') .= withParser schema (either fail pure . runParser parser . cs)

data OAuthAccessTokenResponse = OAuthAccessTokenResponse
  { oatAccessToken :: OAuthAccessToken,
    oatTokenType :: OAuthAccessTokenType,
    oatExpiresIn :: NominalDiffTime
  }
  deriving (Eq, Show, Generic)
  deriving (A.ToJSON, A.FromJSON, S.ToSchema) via (Schema OAuthAccessTokenResponse)

instance ToSchema OAuthAccessTokenResponse where
  schema =
    object "OAuthAccessTokenResponse" $
      OAuthAccessTokenResponse
        <$> oatAccessToken .= field "accessToken" schema
        <*> oatTokenType .= field "tokenType" schema
        <*> oatExpiresIn .= field "expiresIn" (fromIntegral <$> roundDiffTime .= schema)
    where
      roundDiffTime :: NominalDiffTime -> Int32
      roundDiffTime = round

data OAuthClaimSet = OAuthClaimSet {jwtClaims :: ClaimsSet, scope :: OAuthScopes}
  deriving (Eq, Show, Generic)

instance HasClaimsSet OAuthClaimSet where
  claimsSet f s = fmap (\a' -> s {jwtClaims = a'}) (f (jwtClaims s))

instance A.FromJSON OAuthClaimSet where
  parseJSON = A.withObject "OAuthClaimSet" $ \o ->
    OAuthClaimSet
      <$> A.parseJSON (A.Object o)
      <*> o A..: "scope"

instance A.ToJSON OAuthClaimSet where
  toJSON s =
    ins "scope" (scope s) (A.toJSON (jwtClaims s))
    where
      ins k v (A.Object o) = A.Object $ M.insert k (A.toJSON v) o
      ins _ _ a = a

csUserId :: OAuthClaimSet -> Maybe UserId
csUserId =
  view claimSub
    >=> preview string
    >=> either (const Nothing) pure . parseIdFromText

hasScope :: OAuthScope -> OAuthClaimSet -> Bool
hasScope s claims = s `Set.member` unOAuthScopes (scope claims)

verify :: JWK -> SignedJWT -> IO (Either JWTError OAuthClaimSet)
verify k jwt = runJOSE $ do
  let audCheck = const True
  verifyJWT (defaultJWTValidationSettings audCheck) k jwt

--------------------------------------------------------------------------------
-- Errors

data OAuthError
  = OAuthClientNotFound
  | RedirectUrlMissMatch
  | UnsupportedResponseType
  | JwtError
  | OAuthAuthCodeNotFound
  | OAuthFeatureDisabled

type instance MapError 'OAuthClientNotFound = 'StaticError 404 "not-found" "OAuth client not found"

type instance MapError 'RedirectUrlMissMatch = 'StaticError 400 "redirect-url-miss-match" "Redirect URL miss match"

type instance MapError 'UnsupportedResponseType = 'StaticError 400 "unsupported-response-type" "Unsupported response type"

type instance MapError 'JwtError = 'StaticError 500 "jwt-error" "Internal error while creating JWT"

type instance MapError 'OAuthAuthCodeNotFound = 'StaticError 404 "not-found" "OAuth authorization code not found"

type instance MapError 'OAuthFeatureDisabled = 'StaticError 403 "forbidden" "OAuth is disabled"

--------------------------------------------------------------------------------
-- CQL instances

instance Cql OAuthApplicationName where
  ctype = Tagged TextColumn
  toCql = CqlText . fromRange . unOAuthApplicationName
  fromCql (CqlText t) = checkedEither t <&> OAuthApplicationName
  fromCql _ = Left "OAuthApplicationName: Text expected"

instance Cql RedirectUrl where
  ctype = Tagged BlobColumn
  toCql = CqlBlob . toByteString
  fromCql (CqlBlob t) = runParser parser (toStrict t)
  fromCql _ = Left "RedirectUrl: Blob expected"

instance Cql OAuthAuthCode where
  ctype = Tagged AsciiColumn
  toCql = CqlAscii . toText . unOAuthAuthCode
  fromCql (CqlAscii t) = OAuthAuthCode <$> validateBase16 t
  fromCql _ = Left "OAuthAuthCode: Ascii expected"

instance Cql OAuthScope where
  ctype = Tagged TextColumn
  toCql = CqlText . cs . toByteString'
  fromCql (CqlText t) = maybe (Left "invalid oauth scope") Right $ fromByteString' (cs t)
  fromCql _ = Left "OAuthScope: Text expected"
