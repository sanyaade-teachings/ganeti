{-| Implementation of the Ganeti Query2 functionality.

 -}

{-

Copyright (C) 2012 Google Inc.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301, USA.

-}

{-

TODO: problems with the current model:

1. There's nothing preventing a result such as ResultEntry RSNormal
Nothing, or ResultEntry RSNoData (Just ...); ideally, we would
separate the the RSNormal and other types; we would need a new data
type for this, though, with JSON encoding/decoding

2. We don't have a way to 'bind' a FieldDefinition's field type
(e.q. QFTBool) with the actual value that is returned from a
FieldGetter. This means that the various getter functions can return
divergent types for the same field when evaluated against multiple
items. This is bad; it only works today because we 'hide' everything
behind JSValue, but is not nice at all. We should probably remove the
separation between FieldDefinition and the FieldGetter, and introduce
a new abstract data type, similar to QFT*, that contains the values
too.

-}

module Ganeti.Query.Query

    ( query
    , queryFields
    ) where

import Control.Monad (filterM)
import Control.Monad.Trans (lift)
import Data.Maybe (fromMaybe)
import qualified Data.Map as Map

import Ganeti.BasicTypes
import Ganeti.JSON
import Ganeti.Rpc
import Ganeti.Query.Language
import Ganeti.Query.Common
import Ganeti.Query.Filter
import Ganeti.Query.Types
import Ganeti.Query.Node
import Ganeti.Query.Group
import Ganeti.Objects

-- * Helper functions

-- | Builds an unknown field definition.
mkUnknownFDef :: String -> FieldData a b
mkUnknownFDef name =
  ( FieldDefinition name name QFTUnknown ("Unknown field '" ++ name ++ "'")
  , FieldUnknown )

-- | Runs a field getter on the existing contexts.
execGetter :: ConfigData -> b -> a -> FieldGetter a b -> ResultEntry
execGetter _   _ item (FieldSimple getter)  = getter item
execGetter cfg _ item (FieldConfig getter)  = getter cfg item
execGetter _  rt item (FieldRuntime getter) = getter rt item
execGetter _   _ _    FieldUnknown          = rsUnknown

-- * Main query execution

-- | Helper to build the list of requested fields. This transforms the
-- list of string fields to a list of field defs and getters, with
-- some of them possibly being unknown fields.
getSelectedFields :: FieldMap a b  -- ^ Defined fields
                  -> [String]      -- ^ Requested fields
                  -> FieldList a b -- ^ Selected fields
getSelectedFields defined =
  map (\name -> fromMaybe (mkUnknownFDef name) $ name `Map.lookup` defined)

-- | Collect live data from RPC query if enabled.
-- FIXME: Check which fields we actually need and possibly send empty
-- hvs/vgs if no info from hypervisor/volume group respectively
-- is required
maybeCollectLiveData:: Bool -> ConfigData -> [Node] -> IO [(Node, NodeRuntime)]

maybeCollectLiveData False _ nodes =
  return $ zip nodes (repeat $ Left (RpcResultError "Live data disabled"))

maybeCollectLiveData True cfg nodes = do
  let vgs = [clusterVolumeGroupName $ configCluster cfg]
      hvs = clusterEnabledHypervisors $ configCluster cfg
  executeRpcCall nodes (RpcCallNodeInfo vgs hvs)

-- | Check whether list of queried fields contains live fields.
needsLiveData :: [FieldGetter a b] -> Bool
needsLiveData = any (\getter -> case getter of
                     FieldRuntime _ -> True
                     _ -> False)

-- | Main query execution function.
query :: ConfigData   -- ^ The current configuration
      -> Bool         -- ^ Whether to collect live data
      -> Query        -- ^ The query (item, fields, filter)
      -> IO (Result QueryResult) -- ^ Result

query cfg live (Query QRNode fields qfilter) =  runResultT $ do
  cfilter <- resultT $ compileFilter nodeFieldsMap qfilter
  let selected = getSelectedFields nodeFieldsMap fields
      (fdefs, fgetters) = unzip selected
      nodes = Map.elems . fromContainer $ configNodes cfg
      live' = live && needsLiveData fgetters
  -- runs first pass of the filter, without a runtime context; this
  -- will limit the nodes that we'll contact for runtime data
  fnodes <- resultT $ filterM (\n -> evaluateFilter cfg Nothing n cfilter) nodes
  -- here we would run the runtime data gathering, then filter again
  -- the nodes, based on existing runtime data
  nruntimes <- lift $ maybeCollectLiveData live' cfg fnodes
  let fdata = map (\(node, nrt) -> map (execGetter cfg nrt node) fgetters)
              nruntimes
  return QueryResult { qresFields = fdefs, qresData = fdata }

query cfg _ (Query QRGroup fields qfilter) = return $ do
  -- FIXME: want_diskparams is defaulted to false and not taken as parameter
  -- This is because the type for DiskParams is right now too generic for merges
  -- (or else I cannot see how to do this with curent implementation)
  cfilter <- compileFilter groupFieldsMap qfilter
  let selected = getSelectedFields groupFieldsMap fields
      (fdefs, fgetters) = unzip selected
      groups = Map.elems . fromContainer $ configNodegroups cfg
  -- there is no live data for groups, so filtering is much simpler
  fgroups <- filterM (\n -> evaluateFilter cfg Nothing n cfilter) groups
  let fdata = map (\node ->
                       map (execGetter cfg GroupRuntime node) fgetters) fgroups
  return QueryResult {qresFields = fdefs, qresData = fdata }

query _ _ (Query qkind _ _) =
  return . Bad $ "Query '" ++ show qkind ++ "' not supported"

-- | Query fields call.
-- FIXME: Looks generic enough to use a typeclass
queryFields :: QueryFields -> Result QueryFieldsResult
queryFields (QueryFields QRNode fields) =
  let selected = if null fields
                   then map snd $ Map.toAscList nodeFieldsMap
                   else getSelectedFields nodeFieldsMap fields
  in Ok $ QueryFieldsResult (map fst selected)

queryFields (QueryFields QRGroup fields) =
  let selected = if null fields
                   then map snd $ Map.toAscList groupFieldsMap
                   else getSelectedFields groupFieldsMap fields
  in Ok $ QueryFieldsResult (map fst selected)


queryFields (QueryFields qkind _) =
  Bad $ "QueryFields '" ++ show qkind ++ "' not supported"
