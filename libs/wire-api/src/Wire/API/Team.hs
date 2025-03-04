{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}

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

module Wire.API.Team
  ( -- * Team
    Team (..),
    newTeam,
    teamId,
    teamCreator,
    teamName,
    teamIcon,
    teamIconKey,
    teamBinding,
    teamSplashScreen,
    TeamBinding (..),
    Icon (..),

    -- * TeamList
    TeamList (..),
    newTeamList,
    teamListTeams,
    teamListHasMore,

    -- * NewTeam
    BindingNewTeam (..),
    bindingNewTeamObjectSchema,
    NonBindingNewTeam (..),
    NewTeam (..),
    newNewTeam,
    newTeamName,
    newTeamIcon,
    newTeamIconKey,
    newTeamMembers,

    -- * TeamUpdateData
    TeamUpdateData (..),
    newTeamUpdateData,
    newTeamDeleteDataWithCode,
    nameUpdate,
    iconUpdate,
    iconKeyUpdate,
    splashScreenUpdate,

    -- * TeamDeleteData
    TeamDeleteData (..),
    newTeamDeleteData,
    tdAuthPassword,
    tdVerificationCode,
  )
where

import Control.Lens (makeLenses, (?~))
import Data.Aeson (FromJSON, ToJSON, Value (..))
import Data.Aeson.Types (Parser)
import qualified Data.Attoparsec.ByteString as Atto (Parser, string)
import Data.Attoparsec.Combinator (choice)
import Data.ByteString.Conversion
import qualified Data.Code as Code
import Data.Id (TeamId, UserId)
import Data.Misc (PlainTextPassword6)
import Data.Range
import Data.Schema
import qualified Data.Swagger as S
import qualified Data.Text.Encoding as T
import Imports
import Test.QuickCheck.Gen (suchThat)
import Wire.API.Asset (AssetKey)
import Wire.API.Team.Member (TeamMember)
import Wire.Arbitrary (Arbitrary (arbitrary), GenericUniform (..))

--------------------------------------------------------------------------------
-- Team

data Team = Team
  { _teamId :: TeamId,
    _teamCreator :: UserId,
    _teamName :: Text,
    _teamIcon :: Icon,
    _teamIconKey :: Maybe Text,
    _teamBinding :: TeamBinding,
    _teamSplashScreen :: Icon
  }
  deriving stock (Eq, Show, Generic)
  deriving (Arbitrary) via (GenericUniform Team)
  deriving (ToJSON, FromJSON, S.ToSchema) via (Schema Team)

newTeam :: TeamId -> UserId -> Text -> Icon -> TeamBinding -> Team
newTeam tid uid nme ico tb = Team tid uid nme ico Nothing tb DefaultIcon

instance ToSchema Team where
  schema =
    object "Team" $
      Team
        <$> _teamId .= field "id" schema
        <*> _teamCreator .= field "creator" schema
        <*> _teamName .= field "name" schema
        <*> _teamIcon .= field "icon" schema
        <*> _teamIconKey .= maybe_ (optField "icon_key" schema)
        <*> _teamBinding .= (fromMaybe Binding <$> optField "binding" schema)
        <*> _teamSplashScreen .= (fromMaybe DefaultIcon <$> optField "splash_screen" schema)

-- | How a team "binds" its members (users)
--
-- A `Binding` team is the normal team which we see in the UI. A user is
-- on-boarded as part of the team. If the team gets deleted/suspended the user
-- gets deleted/suspended.
--
-- A `NonBinding` team is a concept only in the backend. It is a team someone
-- can create and someone who has an account on Wire can join that team. This
-- way, in theory, one person can join many teams. This concept never made it as
-- a concept of product, but got used a lot of writing integration tests. Newer
-- features don't really work well with this and sometimes we have to rewrite
-- parts of the tests to use `Binding` teams.
--
-- Please try to not use `NonBinding` teams in tests anymore. In future, we
-- would like it to be deleted, but it is hard to delete because it requires a
-- bunch of tests to be rewritten.
data TeamBinding
  = Binding
  | NonBinding
  deriving stock (Eq, Show, Generic)
  deriving (Arbitrary) via (GenericUniform TeamBinding)
  deriving (ToJSON, FromJSON, S.ToSchema) via (Schema TeamBinding)

instance ToSchema TeamBinding where
  schema =
    enum @Bool "TeamBinding" $
      mconcat [element True Binding, element False NonBinding]

--------------------------------------------------------------------------------
-- TeamList

data TeamList = TeamList
  { _teamListTeams :: [Team],
    _teamListHasMore :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving (Arbitrary) via (GenericUniform TeamList)
  deriving (ToJSON, FromJSON, S.ToSchema) via (Schema TeamList)

newTeamList :: [Team] -> Bool -> TeamList
newTeamList = TeamList

instance ToSchema TeamList where
  schema =
    object "TeamList" $
      TeamList
        <$> _teamListTeams .= field "teams" (array schema)
        <*> _teamListHasMore .= field "has_more" schema

--------------------------------------------------------------------------------
-- NewTeam

newtype BindingNewTeam = BindingNewTeam (NewTeam ())
  deriving stock (Eq, Show, Generic)
  deriving (ToJSON, FromJSON, S.ToSchema) via (Schema BindingNewTeam)

instance ToSchema BindingNewTeam where
  schema = object "BindingNewTeam" bindingNewTeamObjectSchema

bindingNewTeamObjectSchema :: ObjectSchema SwaggerDoc BindingNewTeam
bindingNewTeamObjectSchema =
  BindingNewTeam <$> unwrap .= newTeamObjectSchema null_
  where
    unwrap (BindingNewTeam nt) = nt

-- FUTUREWORK: since new team members do not get serialized, we zero them here.
-- it may be worth looking into how this can be solved in the types.
instance Arbitrary BindingNewTeam where
  arbitrary =
    BindingNewTeam . zeroTeamMembers <$> arbitrary @(NewTeam ())
    where
      zeroTeamMembers tms = tms {_newTeamMembers = Nothing}

-- | FUTUREWORK: this is dead code!  remove!
newtype NonBindingNewTeam = NonBindingNewTeam (NewTeam (Range 1 127 [TeamMember]))
  deriving stock (Eq, Show, Generic)
  deriving (FromJSON, ToJSON, S.ToSchema) via (Schema NonBindingNewTeam)

instance ToSchema NonBindingNewTeam where
  schema =
    object "NonBindingNewTeam" $
      NonBindingNewTeam
        <$> unwrap .= newTeamObjectSchema sch
    where
      unwrap (NonBindingNewTeam nt) = nt

      sch :: ValueSchema SwaggerDoc (Range 1 127 [TeamMember])
      sch = fromRange .= rangedSchema (array schema)

data NewTeam a = NewTeam
  { _newTeamName :: Range 1 256 Text,
    _newTeamIcon :: Icon,
    _newTeamIconKey :: Maybe (Range 1 256 Text),
    _newTeamMembers :: Maybe a
  }
  deriving stock (Eq, Show, Generic)
  deriving (Arbitrary) via (GenericUniform (NewTeam a))

newNewTeam :: Range 1 256 Text -> Icon -> NewTeam a
newNewTeam nme ico = NewTeam nme ico Nothing Nothing

newTeamObjectSchema :: ValueSchema SwaggerDoc a -> ObjectSchema SwaggerDoc (NewTeam a)
newTeamObjectSchema sch =
  NewTeam
    <$> _newTeamName .= fieldWithDocModifier "name" (description ?~ "team name") schema
    <*> _newTeamIcon .= fieldWithDocModifier "icon" (description ?~ "team icon (asset ID)") schema
    <*> _newTeamIconKey .= maybe_ (optFieldWithDocModifier "icon_key" (description ?~ "team icon asset key") schema)
    <*> _newTeamMembers .= maybe_ (optFieldWithDocModifier "members" (description ?~ "initial team member ids (between 1 and 127)") sch)

--------------------------------------------------------------------------------
-- TeamUpdateData

data Icon = Icon AssetKey | DefaultIcon
  deriving stock (Eq, Show, Generic)
  deriving (Arbitrary) via (GenericUniform Icon)
  deriving (ToJSON, FromJSON, S.ToSchema) via Schema Icon

instance FromByteString Icon where
  parser =
    choice
      [ Icon <$> (parser :: Atto.Parser AssetKey),
        DefaultIcon <$ Atto.string "default"
      ]

instance ToByteString Icon where
  builder (Icon key) = builder key
  builder DefaultIcon = "default"

instance ToSchema Icon where
  schema =
    (T.decodeUtf8 . toByteString')
      .= parsedText "Icon" (runParser parser . T.encodeUtf8)

data TeamUpdateData = TeamUpdateData
  { _nameUpdate :: Maybe (Range 1 256 Text),
    _iconUpdate :: Maybe Icon,
    _iconKeyUpdate :: Maybe (Range 1 256 Text),
    _splashScreenUpdate :: Maybe Icon
  }
  deriving stock (Eq, Show, Generic)
  deriving (ToJSON, FromJSON, S.ToSchema) via (Schema TeamUpdateData)

instance Arbitrary TeamUpdateData where
  arbitrary = arb `suchThat` valid
    where
      arb = TeamUpdateData <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
      valid (TeamUpdateData Nothing Nothing Nothing Nothing) = False
      valid _ = True

newTeamUpdateData :: TeamUpdateData
newTeamUpdateData = TeamUpdateData Nothing Nothing Nothing Nothing

validateTeamUpdateData :: TeamUpdateData -> Parser TeamUpdateData
validateTeamUpdateData u =
  when
    (isNothing (_nameUpdate u) && isNothing (_iconUpdate u) && isNothing (_iconKeyUpdate u) && isNothing (_splashScreenUpdate u))
    (fail "TeamUpdateData: no update data specified")
    $> u

instance ToSchema TeamUpdateData where
  schema =
    (`withParser` validateTeamUpdateData)
      . object "TeamUpdateData"
      $ TeamUpdateData
        <$> _nameUpdate .= maybe_ (optField "name" schema)
        <*> _iconUpdate .= maybe_ (optField "icon" schema)
        <*> _iconKeyUpdate .= maybe_ (optField "icon_key" schema)
        <*> _splashScreenUpdate .= maybe_ (optField "splash_screen" schema)

--------------------------------------------------------------------------------
-- TeamDeleteData

data TeamDeleteData = TeamDeleteData
  { _tdAuthPassword :: Maybe PlainTextPassword6,
    _tdVerificationCode :: Maybe Code.Value
  }
  deriving stock (Eq, Show)
  deriving (ToJSON, FromJSON, S.ToSchema) via (Schema TeamDeleteData)

instance Arbitrary TeamDeleteData where
  arbitrary = TeamDeleteData <$> arbitrary <*> arbitrary

newTeamDeleteData :: Maybe PlainTextPassword6 -> TeamDeleteData
newTeamDeleteData = flip TeamDeleteData Nothing

newTeamDeleteDataWithCode :: Maybe PlainTextPassword6 -> Maybe Code.Value -> TeamDeleteData
newTeamDeleteDataWithCode = TeamDeleteData

instance ToSchema TeamDeleteData where
  schema =
    object "TeamDeleteData" $
      TeamDeleteData
        <$> _tdAuthPassword .= optField "password" (maybeWithDefault Null schema)
        <*> _tdVerificationCode .= maybe_ (optField "verification_code" schema)

makeLenses ''Team
makeLenses ''TeamList
makeLenses ''NewTeam
makeLenses ''TeamUpdateData
makeLenses ''TeamDeleteData
