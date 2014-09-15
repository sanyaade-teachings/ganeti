{-# LANGUAGE TemplateHaskell #-}

{-| Implementation of the Ganeti LUXI interface.

-}

{-

Copyright (C) 2009, 2010, 2011, 2012, 2013 Google Inc.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-}

module Ganeti.Luxi
  ( LuxiOp(..)
  , LuxiReq(..)
  , Client
  , Server
  , JobId
  , fromJobId
  , makeJobId
  , RecvResult(..)
  , strOfOp
  , opToArgs
  , getLuxiClient
  , getLuxiServer
  , acceptClient
  , closeClient
  , closeServer
  , callMethod
  , submitManyJobs
  , queryJobsStatus
  , buildCall
  , buildResponse
  , decodeLuxiCall
  , recvMsg
  , recvMsgExt
  , sendMsg
  , allLuxiCalls
  ) where

import Control.Applicative (optional)
import Control.Monad
import qualified Text.JSON as J
import Text.JSON.Pretty (pp_value)
import Text.JSON.Types

import Ganeti.BasicTypes
import Ganeti.Constants
import Ganeti.Errors
import Ganeti.JSON
import Ganeti.UDSServer
import Ganeti.OpParams (pTagsObject)
import Ganeti.OpCodes
import qualified Ganeti.Query.Language as Qlang
import Ganeti.Runtime (GanetiDaemon(..))
import Ganeti.THH
import Ganeti.THH.Field
import Ganeti.Types


-- | Currently supported Luxi operations and JSON serialization.
$(genLuxiOp "LuxiOp"
  [ (luxiReqQuery,
    [ simpleField "what"    [t| Qlang.ItemType |]
    , simpleField "fields"  [t| [String]  |]
    , simpleField "qfilter" [t| Qlang.Filter Qlang.FilterField |]
    ])
  , (luxiReqQueryFields,
    [ simpleField "what"    [t| Qlang.ItemType |]
    , simpleField "fields"  [t| [String]  |]
    ])
  , (luxiReqQueryNodes,
     [ simpleField "names"  [t| [String] |]
     , simpleField "fields" [t| [String] |]
     , simpleField "lock"   [t| Bool     |]
     ])
  , (luxiReqQueryGroups,
     [ simpleField "names"  [t| [String] |]
     , simpleField "fields" [t| [String] |]
     , simpleField "lock"   [t| Bool     |]
     ])
  , (luxiReqQueryNetworks,
     [ simpleField "names"  [t| [String] |]
     , simpleField "fields" [t| [String] |]
     , simpleField "lock"   [t| Bool     |]
     ])
  , (luxiReqQueryInstances,
     [ simpleField "names"  [t| [String] |]
     , simpleField "fields" [t| [String] |]
     , simpleField "lock"   [t| Bool     |]
     ])
  , (luxiReqQueryJobs,
     [ simpleField "ids"    [t| [JobId]  |]
     , simpleField "fields" [t| [String] |]
     ])
  , (luxiReqQueryExports,
     [ simpleField "nodes" [t| [String] |]
     , simpleField "lock"  [t| Bool     |]
     ])
  , (luxiReqQueryConfigValues,
     [ simpleField "fields" [t| [String] |] ]
    )
  , (luxiReqQueryClusterInfo, [])
  , (luxiReqQueryTags,
     [ pTagsObject
     , simpleField "name" [t| String |]
     ])
  , (luxiReqSubmitJob,
     [ simpleField "job" [t| [MetaOpCode] |] ]
    )
  , (luxiReqSubmitJobToDrainedQueue,
     [ simpleField "job" [t| [MetaOpCode] |] ]
    )
  , (luxiReqSubmitManyJobs,
     [ simpleField "ops" [t| [[MetaOpCode]] |] ]
    )
  , (luxiReqWaitForJobChange,
     [ simpleField "job"      [t| JobId   |]
     , simpleField "fields"   [t| [String]|]
     , simpleField "prev_job" [t| JSValue |]
     , simpleField "prev_log" [t| JSValue |]
     , simpleField "tmout"    [t| Int     |]
     ])
  , (luxiReqPickupJob,
     [ simpleField "job" [t| JobId |] ]
    )
  , (luxiReqArchiveJob,
     [ simpleField "job" [t| JobId |] ]
    )
  , (luxiReqAutoArchiveJobs,
     [ simpleField "age"   [t| Int |]
     , simpleField "tmout" [t| Int |]
     ])
  , (luxiReqCancelJob,
     [ simpleField "job" [t| JobId |] ]
    )
  , (luxiReqChangeJobPriority,
     [ simpleField "job"      [t| JobId |]
     , simpleField "priority" [t| Int |] ]
    )
  , (luxiReqSetDrainFlag,
     [ simpleField "flag" [t| Bool |] ]
    )
  , (luxiReqSetWatcherPause,
     [ optionalNullSerField
         $ timeAsDoubleField "duration" ]
    )
  ])

$(makeJSONInstance ''LuxiReq)

-- | List of all defined Luxi calls.
$(genAllConstr (drop 3) ''LuxiReq "allLuxiCalls")

-- | The serialisation of LuxiOps into strings in messages.
$(genStrOfOp ''LuxiOp "strOfOp")


luxiConnectConfig :: ServerConfig
luxiConnectConfig = ServerConfig GanetiLuxid
                      ConnectConfig { recvTmo    = luxiDefRwto
                                    , sendTmo    = luxiDefRwto
                                    }

-- | Connects to the master daemon and returns a luxi Client.
getLuxiClient :: String -> IO Client
getLuxiClient = connectClient (connConfig luxiConnectConfig) luxiDefCtmo

-- | Creates and returns a server endpoint.
getLuxiServer :: Bool -> FilePath -> IO Server
getLuxiServer = connectServer luxiConnectConfig


-- | Converts Luxi call arguments into a 'LuxiOp' data structure.
-- This is used for building a Luxi 'Handler'.
--
-- This is currently hand-coded until we make it more uniform so that
-- it can be generated using TH.
decodeLuxiCall :: JSValue -> JSValue -> Result LuxiOp
decodeLuxiCall method args = do
  call <- fromJResult "Unable to parse LUXI request method" $ J.readJSON method
  case call of
    ReqQueryJobs -> do
              (jids, jargs) <- fromJVal args
              jids' <- case jids of
                         JSNull -> return []
                         _ -> fromJVal jids
              return $ QueryJobs jids' jargs
    ReqQueryInstances -> do
              (names, fields, locking) <- fromJVal args
              return $ QueryInstances names fields locking
    ReqQueryNodes -> do
              (names, fields, locking) <- fromJVal args
              return $ QueryNodes names fields locking
    ReqQueryGroups -> do
              (names, fields, locking) <- fromJVal args
              return $ QueryGroups names fields locking
    ReqQueryClusterInfo ->
              return QueryClusterInfo
    ReqQueryNetworks -> do
              (names, fields, locking) <- fromJVal args
              return $ QueryNetworks names fields locking
    ReqQuery -> do
              (what, fields, qfilter) <- fromJVal args
              return $ Query what fields qfilter
    ReqQueryFields -> do
              (what, fields) <- fromJVal args
              fields' <- case fields of
                           JSNull -> return []
                           _ -> fromJVal fields
              return $ QueryFields what fields'
    ReqSubmitJob -> do
              [ops1] <- fromJVal args
              ops2 <- mapM (fromJResult (luxiReqToRaw call) . J.readJSON) ops1
              return $ SubmitJob ops2
    ReqSubmitJobToDrainedQueue -> do
              [ops1] <- fromJVal args
              ops2 <- mapM (fromJResult (luxiReqToRaw call) . J.readJSON) ops1
              return $ SubmitJobToDrainedQueue ops2
    ReqSubmitManyJobs -> do
              [ops1] <- fromJVal args
              ops2 <- mapM (fromJResult (luxiReqToRaw call) . J.readJSON) ops1
              return $ SubmitManyJobs ops2
    ReqWaitForJobChange -> do
              (jid, fields, pinfo, pidx, wtmout) <-
                -- No instance for 5-tuple, code copied from the
                -- json sources and adapted
                fromJResult "Parsing WaitForJobChange message" $
                case args of
                  JSArray [a, b, c, d, e] ->
                    (,,,,) `fmap`
                    J.readJSON a `ap`
                    J.readJSON b `ap`
                    J.readJSON c `ap`
                    J.readJSON d `ap`
                    J.readJSON e
                  _ -> J.Error "Not enough values"
              return $ WaitForJobChange jid fields pinfo pidx wtmout
    ReqPickupJob -> do
              [jid] <- fromJVal args
              return $ PickupJob jid
    ReqArchiveJob -> do
              [jid] <- fromJVal args
              return $ ArchiveJob jid
    ReqAutoArchiveJobs -> do
              (age, tmout) <- fromJVal args
              return $ AutoArchiveJobs age tmout
    ReqQueryExports -> do
              (nodes, lock) <- fromJVal args
              return $ QueryExports nodes lock
    ReqQueryConfigValues -> do
              [fields] <- fromJVal args
              return $ QueryConfigValues fields
    ReqQueryTags -> do
              (kind, name) <- fromJVal args
              return $ QueryTags kind name
    ReqCancelJob -> do
              [jid] <- fromJVal args
              return $ CancelJob jid
    ReqChangeJobPriority -> do
              (jid, priority) <- fromJVal args
              return $ ChangeJobPriority jid priority
    ReqSetDrainFlag -> do
              [flag] <- fromJVal args
              return $ SetDrainFlag flag
    ReqSetWatcherPause -> do
              duration <- optional $ do
                [x] <- fromJVal args
                liftM unTimeAsDoubleJSON $ fromJVal x
              return $ SetWatcherPause duration

-- | Generic luxi method call
callMethod :: LuxiOp -> Client -> IO (ErrorResult JSValue)
callMethod method s = do
  sendMsg s $ buildCall (strOfOp method) (opToArgs method)
  result <- recvMsg s
  return $ parseResponse result

-- | Parse job submission result.
parseSubmitJobResult :: JSValue -> ErrorResult JobId
parseSubmitJobResult (JSArray [JSBool True, v]) =
  case J.readJSON v of
    J.Error msg -> Bad $ LuxiError msg
    J.Ok v' -> Ok v'
parseSubmitJobResult (JSArray [JSBool False, JSString x]) =
  Bad . LuxiError $ fromJSString x
parseSubmitJobResult v =
  Bad . LuxiError $ "Unknown result from the master daemon: " ++
      show (pp_value v)

-- | Specialized submitManyJobs call.
submitManyJobs :: Client -> [[MetaOpCode]] -> IO (ErrorResult [JobId])
submitManyJobs s jobs = do
  rval <- callMethod (SubmitManyJobs jobs) s
  -- map each result (status, payload) pair into a nice Result ADT
  return $ case rval of
             Bad x -> Bad x
             Ok (JSArray r) -> mapM parseSubmitJobResult r
             x -> Bad . LuxiError $
                  "Cannot parse response from Ganeti: " ++ show x

-- | Custom queryJobs call.
queryJobsStatus :: Client -> [JobId] -> IO (ErrorResult [JobStatus])
queryJobsStatus s jids = do
  rval <- callMethod (QueryJobs jids ["status"]) s
  return $ case rval of
             Bad x -> Bad x
             Ok y -> case J.readJSON y::(J.Result [[JobStatus]]) of
                       J.Ok vals -> if any null vals
                                    then Bad $
                                         LuxiError "Missing job status field"
                                    else Ok (map head vals)
                       J.Error x -> Bad $ LuxiError x
