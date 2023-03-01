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

module Wire.API.MLS.LeafNode where

import Imports
import Wire.API.MLS.Capabilities
import Wire.API.MLS.Credential
import Wire.API.MLS.Extension
import Wire.API.MLS.HPKEPublicKey
import Wire.API.MLS.Lifetime
import Wire.API.MLS.Serialisation
import Wire.API.MLS.SignaturePublicKey

data LeafNodeTBS = LeafNodeTBS
  { encryptionKey :: HPKEPublicKey,
    signatureKey :: SignaturePublicKey,
    credential :: Credential,
    capabilities :: Capabilities,
    leafNodeSource :: LeafNodeSource,
    extensions :: [Extension]
  }
  deriving (Show, Eq)

-- | This type can only verify the signature when the LeafNodeSource is
-- LeafNodeSourceKeyPackage
data LeafNode = LeafNode
  { tbs :: LeafNodeTBS,
    signature_ :: ByteString
  }

data LeafNodeSource
  = LeafNodeSourceKeyPackage Lifetime
  | LeafNodeSourceUpdate
  | LeafNodeSourceCommit ByteString

instance ParseMLS LeafNodeSource where
  parseMLS =
    parseMLS >>= \case
      LeafNodeSourceKeyPackageTag -> LeafNodeSourceKeyPackage <$> parseMLS
      LeafNodeSourceUpdateTag -> pure LeafNodeSourceUpdate
      LeafNodeSourceCommitTag -> LeafNodeSourceCommit <$> parseMLSBytes @VarInt

data LeafNodeSourceTag
  = LeafNodeSourceKeyPackageTag
  | LeafNodeSourceUpdateTag
  | LeafNodeSourceCommitTag
  deriving (Show, Eq, Ord, Enum, Bounded)

instance Bounded LeafNodeSourceTag => ParseMLS LeafNodeSourceTag where
  parseMLS = parseMLSEnum @Word8 "leaf node source"
