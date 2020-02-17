module Brig.User.API.Search (routes) where

import Brig.API.Handler
import Brig.App
import qualified Brig.Data.User as DB
import Brig.Types.Search
import qualified Brig.Types.Swagger as Doc
import Brig.User.Search.Index
import Data.Id
import Data.Predicate
import Data.Range
import qualified Data.Swagger.Build.Api as Doc
import Imports
import Network.Wai (Response)
import Network.Wai.Predicate hiding (setStatus)
import Network.Wai.Routing
import Network.Wai.Utilities.Response (empty, json)
import Network.Wai.Utilities.Swagger (document)

routes :: Routes Doc.ApiBuilder Handler ()
routes = do
  get "/search/contacts" (continue searchH) $
    accept "application" "json"
      .&. header "Z-User"
      .&. query "q"
      .&. def (unsafeRange 15) (query "size")
  document "GET" "search" $ do
    Doc.summary "Search for users"
    Doc.parameter Doc.Query "q" Doc.string' $
      Doc.description "Search query"
    Doc.parameter Doc.Query "size" Doc.int32' $ do
      Doc.description "Number of results to return"
      Doc.optional
    Doc.returns (Doc.ref Doc.searchResult)
    Doc.response 200 "The search result." Doc.end
  --

  -- make index updates visible (e.g. for integration testing)
  post
    "/i/index/refresh"
    (continue (const $ lift refreshIndex *> pure empty))
    true
  -- reindex from Cassandra (e.g. integration testing -- prefer the
  -- `brig-index` executable for actual operations!)
  post
    "/i/index/reindex"
    (continue . const $ lift reindexAll *> pure empty)
    true

-- Handlers

searchH :: JSON ::: UserId ::: Text ::: Range 1 100 Int32 -> Handler Response
searchH (_ ::: u ::: q ::: s) = json <$> lift (search u q s)

search :: UserId -> Text -> Range 1 100 Int32 -> AppIO (SearchResult Contact)
search searcherId searchTerm maxResults = do
  searcherTeamId <- DB.lookupUserTeam searcherId
  searchIndex searcherId searcherTeamId searchTerm maxResults
