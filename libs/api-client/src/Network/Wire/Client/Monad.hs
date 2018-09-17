{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}

module Network.Wire.Client.Monad
    ( Service (..)
    , Server (..)
    , setServer
    , Client
    , MonadClient (..)
    , asyncClient
    , runClient
    , ClientException (..)
    ) where

import Bilge
import Control.Applicative
import Control.Concurrent.Async
import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.Trans.Reader
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Typeable
import Data.Word (Word16)
import Network.HTTP.Types
import System.Logger.Class
import Prelude hiding (log)

import qualified System.Logger as Logger

data Service = Brig | Galley | Gundeck | Cargohold | Cannon | Proxy | Spar
    deriving (Eq, Ord, Show)

data Env = Env
    { clientServer  :: Service -> Server
    , clientLogger  :: Logger
    , clientManager :: Manager
    }

newtype Client a = Client (ReaderT Env IO a)
    deriving (Functor, Applicative, Monad, MonadIO)

data Server = Server
    { serverHost    :: ByteString
    , serverPort    :: Word16
    , serverWsHost  :: Maybe ByteString
    , serverWsPort  :: Maybe Word16
    , serverSSL     :: Bool
    }

class (MonadHttp m, MonadLogger m, MonadIO m) => MonadClient m where
    getServer :: Service -> m Server
    getLogger :: m Logger

instance MonadHttp Client where
    getManager = Client $ asks clientManager

instance MonadClient Client where
    getServer service = Client $ fmap ($ service) $ asks clientServer
    getLogger = Client $ asks clientLogger

instance MonadLogger Client where
    log l m = getLogger >>= \lg -> Logger.log lg l m

setServer :: Server -> Request -> Request
setServer (Server h p _ _ s) = host h . port p . (if s then secure else id)

asyncClient :: Client a -> Client (Async a)
asyncClient (Client c) = Client $ mapReaderT async c

runClient :: MonadIO m => (Service -> Server) -> Logger -> Manager -> Client a -> m a
runClient s l m (Client c) = liftIO $ runReaderT c (Env s l m)

data ClientException
    = ErrorResponse Int Text Text
        -- ^ An error response from the API (code + label + message)
    | UnexpectedResponse Status ResponseHeaders Text
        -- ^ An unexpected response from the API.
    | ParseError Text
        -- ^ A response body could not be parsed.
    deriving (Show, Typeable)

instance Exception ClientException
