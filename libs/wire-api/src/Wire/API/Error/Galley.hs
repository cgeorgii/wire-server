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
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module Wire.API.Error.Galley
  ( GalleyError (..),
    OperationDenied,
    MLSProtocolError,
    mlsProtocolError,
    AuthenticationError (..),
    TeamFeatureError (..),
    MLSProposalFailure (..),
  )
where

import Control.Lens ((%~))
import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Singletons.TH (genSingletons)
import qualified Data.Swagger as S
import Data.Tagged
import GHC.TypeLits
import Imports
import qualified Network.Wai.Utilities.Error as Wai
import Polysemy
import Polysemy.Error
import Prelude.Singletons (Show_)
import Wire.API.Conversation.Role
import Wire.API.Error
import qualified Wire.API.Error.Brig as BrigError
import Wire.API.Routes.API
import Wire.API.Team.Member
import Wire.API.Team.Permission
import Wire.API.Util.Aeson (CustomEncoded (..))

data GalleyError
  = InvalidAction
  | InvalidTargetAccess
  | TeamNotFound
  | TeamMemberNotFound
  | NotATeamMember
  | NonBindingTeam
  | BroadcastLimitExceeded
  | UserBindingExists
  | NoAddToBinding
  | TooManyTeamMembers
  | -- FUTUREWORK: possibly make MissingPermission take a list of Perm
    MissingPermission (Maybe Perm)
  | ActionDenied Action
  | NotConnected
  | InvalidOperation
  | InvalidTarget
  | ConvNotFound
  | ConvAccessDenied
  | -- MLS Errors
    MLSNotEnabled
  | MLSNonEmptyMemberList
  | MLSDuplicatePublicKey
  | MLSKeyPackageRefNotFound
  | MLSUnsupportedMessage
  | MLSProposalNotFound
  | MLSUnsupportedProposal
  | MLSProtocolErrorTag
  | MLSClientMismatch
  | MLSStaleMessage
  | MLSCommitMissingReferences
  | MLSSelfRemovalNotAllowed
  | MLSGroupConversationMismatch
  | MLSClientSenderUserMismatch
  | MLSWelcomeMismatch
  | MLSMissingGroupInfo
  | MLSMissingSenderClient
  | --
    NoBindingTeamMembers
  | NoBindingTeam
  | NotAOneMemberTeam
  | TooManyMembers
  | ConvMemberNotFound
  | GuestLinksDisabled
  | CodeNotFound
  | InvalidConversationPassword
  | CreateConversationCodeConflict
  | InvalidPermissions
  | InvalidTeamStatusUpdate
  | AccessDenied
  | CustomBackendNotFound
  | DeleteQueueFull
  | TeamSearchVisibilityNotEnabled
  | CannotEnableLegalHoldServiceLargeTeam
  | -- Legal hold Error
    -- FUTUREWORK: make LegalHoldError more static and documented
    MissingLegalholdConsent
  | NoUserLegalHoldConsent
  | LegalHoldNotEnabled
  | LegalHoldDisableUnimplemented
  | LegalHoldServiceInvalidKey
  | LegalHoldServiceBadResponse
  | UserLegalHoldAlreadyEnabled
  | LegalHoldServiceNotRegistered
  | LegalHoldCouldNotBlockConnections
  | UserLegalHoldIllegalOperation
  | TooManyTeamMembersOnTeamWithLegalhold
  | NoLegalHoldDeviceAllocated
  | UserLegalHoldNotPending
  | -- Team Member errors
    BulkGetMemberLimitExceeded
  | -- Team Notification errors
    InvalidTeamNotificationId
  deriving (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via (CustomEncoded GalleyError)

$(genSingletons [''GalleyError])

instance KnownError (MapError e) => IsSwaggerError (e :: GalleyError) where
  addToSwagger = addStaticErrorToSwagger @(MapError e)

instance KnownError (MapError e) => APIError (Tagged (e :: GalleyError) ()) where
  toWai _ = toWai $ dynError @(MapError e)

-- | Convenience synonym for an operation denied error with an unspecified permission.
type OperationDenied = 'MissingPermission 'Nothing

-- | An MLS protocol error with associated text.
type MLSProtocolError = Tagged 'MLSProtocolErrorTag Text

-- | Create an MLS protocol error value.
mlsProtocolError :: Text -> MLSProtocolError
mlsProtocolError = Tagged

type family GalleyErrorEffect (e :: GalleyError) :: Effect where
  GalleyErrorEffect 'MLSProtocolErrorTag = Error MLSProtocolError
  GalleyErrorEffect e = ErrorS e

type instance ErrorEffect (e :: GalleyError) = GalleyErrorEffect e

type instance MapError 'InvalidAction = 'StaticError 400 "invalid-actions" "The specified actions are invalid"

type instance MapError 'InvalidTargetAccess = 'StaticError 403 "invalid-op" "Invalid target access"

type instance MapError 'TeamNotFound = 'StaticError 404 "no-team" "Team not found"

type instance MapError 'NonBindingTeam = 'StaticError 404 "non-binding-team" "Not a member of a binding team"

type instance MapError 'BroadcastLimitExceeded = 'StaticError 400 "too-many-users-to-broadcast" "Too many users to fan out the broadcast event to"

type instance MapError 'TeamMemberNotFound = 'StaticError 404 "no-team-member" "Team member not found"

type instance MapError 'NotATeamMember = 'StaticError 403 "no-team-member" "Requesting user is not a team member"

type instance MapError 'UserBindingExists = 'StaticError 403 "binding-exists" "User already bound to a different team"

type instance MapError 'NoAddToBinding = 'StaticError 403 "binding-team" "Cannot add users to binding teams, invite only"

type instance MapError 'TooManyTeamMembers = 'StaticError 403 "too-many-team-members" "Maximum number of members per team reached"

type instance MapError ('MissingPermission mperm) = 'StaticError 403 "operation-denied" (MissingPermissionMessage mperm)

type instance MapError ('ActionDenied action) = 'StaticError 403 "action-denied" ("Insufficient authorization (missing " `AppendSymbol` ActionName action `AppendSymbol` ")")

type instance MapError 'NotConnected = 'StaticError 403 "not-connected" "Users are not connected"

type instance MapError 'InvalidOperation = 'StaticError 403 "invalid-op" "Invalid operation"

type instance MapError 'InvalidTarget = 'StaticError 403 "invalid-op" "Invalid target"

type instance MapError 'ConvNotFound = 'StaticError 404 "no-conversation" "Conversation not found"

type instance MapError 'ConvAccessDenied = 'StaticError 403 "access-denied" "Conversation access denied"

type instance MapError 'InvalidTeamNotificationId = 'StaticError 400 "invalid-notification-id" "Could not parse notification id (must be UUIDv1)."

type instance
  MapError 'MLSNotEnabled =
    'StaticError
      400
      "mls-not-enabled"
      "MLS is not configured on this backend. See docs.wire.com for instructions on how to enable it"

type instance MapError 'MLSNonEmptyMemberList = 'StaticError 400 "non-empty-member-list" "Attempting to add group members outside MLS"

type instance MapError 'MLSDuplicatePublicKey = 'StaticError 400 "mls-duplicate-public-key" "MLS public key for the given signature scheme already exists"

type instance MapError 'MLSKeyPackageRefNotFound = 'StaticError 404 "mls-key-package-ref-not-found" "A referenced key package could not be mapped to a known client"

type instance MapError 'MLSUnsupportedMessage = 'StaticError 422 "mls-unsupported-message" "Attempted to send a message with an unsupported combination of content type and wire format"

type instance MapError 'MLSProposalNotFound = 'StaticError 404 "mls-proposal-not-found" "A proposal referenced in a commit message could not be found"

type instance MapError 'MLSUnsupportedProposal = 'StaticError 422 "mls-unsupported-proposal" "Unsupported proposal type"

type instance MapError 'MLSProtocolErrorTag = MapError 'BrigError.MLSProtocolError

type instance MapError 'MLSClientMismatch = 'StaticError 409 "mls-client-mismatch" "A proposal of type Add or Remove does not apply to the full list of clients for a user"

type instance MapError 'MLSStaleMessage = 'StaticError 409 "mls-stale-message" "The conversation epoch in a message is too old"

type instance MapError 'MLSCommitMissingReferences = 'StaticError 400 "mls-commit-missing-references" "The commit is not referencing all pending proposals"

type instance MapError 'MLSSelfRemovalNotAllowed = 'StaticError 400 "mls-self-removal-not-allowed" "Self removal from group is not allowed"

type instance MapError 'MLSGroupConversationMismatch = 'StaticError 400 "mls-group-conversation-mismatch" "Conversation ID resolved from Group ID does not match submitted Conversation ID"

type instance MapError 'MLSClientSenderUserMismatch = 'StaticError 400 "mls-client-sender-user-mismatch" "User ID resolved from Client ID does not match message's sender user ID"

type instance MapError 'MLSWelcomeMismatch = 'StaticError 400 "mls-welcome-mismatch" "The list of targets of a welcome message does not match the list of new clients in a group"

type instance MapError 'MLSMissingGroupInfo = 'StaticError 404 "mls-missing-group-info" "The conversation has no group information"

type instance MapError 'MLSMissingSenderClient = 'StaticError 403 "mls-missing-sender-client" "The client has to refresh their access token and provide their client ID"

type instance MapError 'NoBindingTeamMembers = 'StaticError 403 "non-binding-team-members" "Both users must be members of the same binding team"

type instance MapError 'NoBindingTeam = 'StaticError 403 "no-binding-team" "Operation allowed only on binding teams"

type instance MapError 'NotAOneMemberTeam = 'StaticError 403 "not-one-member-team" "Can only delete teams with a single member"

type instance MapError 'TooManyMembers = 'StaticError 403 "too-many-members" "Maximum number of members per conversation reached"

type instance MapError 'ConvMemberNotFound = 'StaticError 404 "no-conversation-member" "Conversation member not found"

type instance MapError 'GuestLinksDisabled = 'StaticError 409 "guest-links-disabled" "The guest link feature is disabled and all guest links have been revoked"

type instance MapError 'CodeNotFound = 'StaticError 404 "no-conversation-code" "Conversation code not found"

type instance MapError 'InvalidConversationPassword = 'StaticError 403 "invalid-conversation-password" "Invalid conversation password"

type instance MapError 'CreateConversationCodeConflict = 'StaticError 409 "create-conv-code-conflict" "Conversation code already exists with a different password setting than the requested one."

type instance MapError 'InvalidPermissions = 'StaticError 403 "invalid-permissions" "The specified permissions are invalid"

type instance MapError 'InvalidTeamStatusUpdate = 'StaticError 403 "invalid-team-status-update" "Cannot use this endpoint to update the team to the given status."

type instance MapError 'AccessDenied = 'StaticError 403 "access-denied" "You do not have permission to access this resource"

type instance MapError 'CustomBackendNotFound = 'StaticError 404 "custom-backend-not-found" "Custom backend not found"

type instance MapError 'DeleteQueueFull = 'StaticError 503 "queue-full" "The delete queue is full; no further delete requests can be processed at the moment"

type instance MapError 'TeamSearchVisibilityNotEnabled = 'StaticError 403 "team-search-visibility-not-enabled" "Custom search is not available for this team"

type instance MapError 'CannotEnableLegalHoldServiceLargeTeam = 'StaticError 403 "too-large-team-for-legalhold" "Cannot enable legalhold on large teams (reason: for removing LH from team, we need to iterate over all members, which is only supported for teams with less than 2k members)"

-- We need this to document possible (operation denied) errors in the servant routes.
type family MissingPermissionMessage (a :: Maybe Perm) :: Symbol where
  MissingPermissionMessage ('Just p) = "Insufficient permissions (missing " `AppendSymbol` Show_ p `AppendSymbol` ")"
  MissingPermissionMessage 'Nothing = "Insufficient permissions"

--------------------------------------------------------------------------------
-- Legal hold Errors

type instance MapError 'TooManyTeamMembersOnTeamWithLegalhold = 'StaticError 403 "too-many-members-for-legalhold" "cannot add more members to team when legalhold service is enabled."

type instance MapError 'LegalHoldServiceInvalidKey = 'StaticError 400 "legalhold-invalid-key" "legal hold service pubkey is invalid"

type instance MapError 'MissingLegalholdConsent = 'StaticError 403 "missing-legalhold-consent" "Failed to connect to a user or to invite a user to a group because somebody is under legalhold and somebody else has not granted consent"

type instance MapError 'LegalHoldServiceNotRegistered = 'StaticError 400 "legalhold-not-registered" "legal hold service has not been registered for this team"

type instance MapError 'LegalHoldServiceBadResponse = 'StaticError 400 "legalhold-status-bad" "legal hold service: invalid response"

type instance MapError 'LegalHoldNotEnabled = 'StaticError 403 "legalhold-not-enabled" "legal hold is not enabled for this team"

type instance MapError 'LegalHoldDisableUnimplemented = 'StaticError 403 "legalhold-disable-unimplemented" "legal hold cannot be disabled for whitelisted teams"

type instance MapError 'UserLegalHoldAlreadyEnabled = 'StaticError 409 "legalhold-already-enabled" "legal hold is already enabled for this user"

type instance MapError 'NoUserLegalHoldConsent = 'StaticError 409 "legalhold-no-consent" "user has not given consent to using legal hold"

type instance MapError 'UserLegalHoldIllegalOperation = 'StaticError 500 "legalhold-illegal-op" "internal server error: inconsistent change of user's legalhold state"

type instance MapError 'UserLegalHoldNotPending = 'StaticError 412 "legalhold-not-pending" "legal hold cannot be approved without being in a pending state"

type instance MapError 'NoLegalHoldDeviceAllocated = 'StaticError 404 "legalhold-no-device-allocated" "no legal hold device is registered for this user. POST /teams/:tid/legalhold/:uid/ to start the flow."

type instance MapError 'LegalHoldCouldNotBlockConnections = 'StaticError 500 "legalhold-internal" "legal hold service: could not block connections when resolving policy conflicts."

--------------------------------------------------------------------------------
-- Team Member errors

type instance MapError 'BulkGetMemberLimitExceeded = 'StaticError 400 "too-many-uids" ("Can only process " `AppendSymbol` Show_ HardTruncationLimit `AppendSymbol` " user ids per request.")

--------------------------------------------------------------------------------
-- Authentication errors

data AuthenticationError
  = ReAuthFailed
  | VerificationCodeAuthFailed
  | VerificationCodeRequired

type instance MapError 'ReAuthFailed = 'StaticError 403 "access-denied" "This operation requires reauthentication"

type instance MapError 'VerificationCodeAuthFailed = 'StaticError 403 "code-authentication-failed" "Code authentication failed"

type instance MapError 'VerificationCodeRequired = 'StaticError 403 "code-authentication-required" "Verification code required"

instance IsSwaggerError AuthenticationError where
  addToSwagger =
    addStaticErrorToSwagger @(MapError 'ReAuthFailed)
      . addStaticErrorToSwagger @(MapError 'VerificationCodeAuthFailed)
      . addStaticErrorToSwagger @(MapError 'VerificationCodeRequired)

type instance ErrorEffect AuthenticationError = Error AuthenticationError

authenticationErrorToDyn :: AuthenticationError -> DynError
authenticationErrorToDyn ReAuthFailed = dynError @(MapError 'ReAuthFailed)
authenticationErrorToDyn VerificationCodeAuthFailed = dynError @(MapError 'VerificationCodeAuthFailed)
authenticationErrorToDyn VerificationCodeRequired = dynError @(MapError 'VerificationCodeRequired)

instance Member (Error DynError) r => ServerEffect (Error AuthenticationError) r where
  interpretServerEffect = mapError authenticationErrorToDyn

--------------------------------------------------------------------------------
-- Team feature errors

data TeamFeatureError
  = AppLockInactivityTimeoutTooLow
  | LegalHoldFeatureFlagNotEnabled
  | LegalHoldWhitelistedOnly
  | DisableSsoNotImplemented
  | FeatureLocked

instance IsSwaggerError TeamFeatureError where
  -- Do not display in Swagger
  addToSwagger = id

type instance MapError 'AppLockInactivityTimeoutTooLow = 'StaticError 400 "inactivity-timeout-too-low" "Applock inactivity timeout must be at least 30 seconds"

type instance MapError 'LegalHoldFeatureFlagNotEnabled = 'StaticError 403 "legalhold-not-enabled" "Legal hold is not enabled for this wire instance"

type instance MapError 'LegalHoldWhitelistedOnly = 'StaticError 403 "legalhold-whitelisted-only" "Legal hold is enabled for teams via server config and cannot be changed here"

type instance
  MapError 'DisableSsoNotImplemented =
    'StaticError
      403
      "not-implemented"
      "The SSO feature flag is disabled by default.  It can only be enabled once for any team, never disabled.\n\
      \\n\
      \Rationale: there are two services in the backend that need to keep their status in sync: galley (teams),\n\
      \and spar (SSO).  Galley keeps track of team features.  If galley creates an idp, the feature flag is\n\
      \checked.  For authentication, spar avoids this expensive check and assumes that the idp can only have\n\
      \been created if the SSO is enabled.  This assumption does not hold any more if the switch is turned off\n\
      \again, so we do not support this.\n\
      \\n\
      \It is definitely feasible to change this.  If you have a use case, please contact customer support, or\n\
      \open an issue on https://github.com/wireapp/wire-server."

type instance MapError 'FeatureLocked = 'StaticError 409 "feature-locked" "Feature config cannot be updated (e.g. because it is configured to be locked, or because you need to upgrade your plan)"

type instance ErrorEffect TeamFeatureError = Error TeamFeatureError

instance Member (Error DynError) r => ServerEffect (Error TeamFeatureError) r where
  interpretServerEffect = mapError $ \case
    AppLockInactivityTimeoutTooLow -> dynError @(MapError 'AppLockInactivityTimeoutTooLow)
    LegalHoldFeatureFlagNotEnabled -> dynError @(MapError 'LegalHoldFeatureFlagNotEnabled)
    LegalHoldWhitelistedOnly -> dynError @(MapError 'LegalHoldWhitelistedOnly)
    DisableSsoNotImplemented -> dynError @(MapError 'DisableSsoNotImplemented)
    FeatureLocked -> dynError @(MapError 'FeatureLocked)

--------------------------------------------------------------------------------
-- Proposal failure

data MLSProposalFailure = MLSProposalFailure
  { pfInner :: Wai.Error
  }

type instance ErrorEffect MLSProposalFailure = Error MLSProposalFailure

-- Proposal failures are only reported generically in Swagger
instance IsSwaggerError MLSProposalFailure where
  addToSwagger = S.allOperations . S.description %~ Just . (<> desc) . fold
    where
      desc =
        "\n\n**Note**: this endpoint can execute proposals, and therefore \
        \return all possible errors associated with adding or removing members to \
        \a conversation, in addition to the ones listed below. See the documentation of [POST \
        \/conversations/{cnv}/members/v2](#/default/post_conversations__cnv__members_v2) \
        \and [POST \
        \/conversations/{cnv_domain}/{cnv}/members/{usr_domain}/{usr}](#/default/delete_conversations__cnv_domain___cnv__members__usr_domain___usr_) \
        \for more details on the possible error responses of each type of \
        \proposal."

instance Member (Error Wai.Error) r => ServerEffect (Error MLSProposalFailure) r where
  interpretServerEffect = mapError pfInner
