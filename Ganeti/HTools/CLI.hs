{-| Implementation of command-line functions.

This module holds the common cli-related functions for the binaries,
separated into this module since Utils.hs is used in many other places
and this is more IO oriented.

-}

{-

Copyright (C) 2009 Google Inc.

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

module Ganeti.HTools.CLI
    ( CLIOptions(..)
    , EToolOptions(..)
    , parseOpts
    , parseEnv
    , shTemplate
    , loadExternalData
    ) where

import System.Console.GetOpt
import System.Posix.Env
import System.IO
import System.Info
import System
import Monad
import Text.Printf (printf)
import qualified Data.Version

import qualified Ganeti.HTools.Version as Version(version)
import qualified Ganeti.HTools.Rapi as Rapi
import qualified Ganeti.HTools.Text as Text
import qualified Ganeti.HTools.Loader as Loader
import qualified Ganeti.HTools.Instance as Instance
import qualified Ganeti.HTools.Node as Node

import Ganeti.HTools.Types

-- | Class for types which support show help and show version.
class CLIOptions a where
    -- | Denotes whether the show help option has been passed.
    showHelp    :: a -> Bool
    -- | Denotes whether the show version option has been passed.
    showVersion :: a -> Bool

-- | Class for types which support the -i\/-n\/-m options.
class EToolOptions a where
    -- | Returns the node file name.
    nodeFile   :: a -> FilePath
    -- | Tells whether the node file has been passed as an option.
    nodeSet    :: a -> Bool
    -- | Returns the instance file name.
    instFile   :: a -> FilePath
    -- | Tells whether the instance file has been passed as an option.
    instSet    :: a -> Bool
    -- | Rapi target, if one has been passed.
    masterName :: a -> String
    -- | Whether to be less verbose.
    silent     :: a -> Bool

-- | Usage info
usageHelp :: (CLIOptions a) => String -> [OptDescr (a -> a)] -> String
usageHelp progname options =
    usageInfo (printf "%s %s\nUsage: %s [OPTION...]"
               progname Version.version progname) options

-- | Command line parser, using the 'options' structure.
parseOpts :: (CLIOptions b) =>
             [String]            -- ^ The command line arguments
          -> String              -- ^ The program name
          -> [OptDescr (b -> b)] -- ^ The supported command line options
          -> b                   -- ^ The default options record
          -> IO (b, [String])    -- ^ The resulting options a leftover
                                 -- arguments
parseOpts argv progname options defaultOptions =
    case getOpt Permute options argv of
      (o, n, []) ->
          do
            let resu@(po, _) = (foldl (flip id) defaultOptions o, n)
            when (showHelp po) $ do
              putStr $ usageHelp progname options
              exitWith ExitSuccess
            when (showVersion po) $ do
              printf "%s %s\ncompiled with %s %s\nrunning on %s %s\n"
                     progname Version.version
                     compilerName (Data.Version.showVersion compilerVersion)
                     os arch
              exitWith ExitSuccess
            return resu
      (_, _, errs) ->
          ioError (userError (concat errs ++ usageHelp progname options))

-- | Parse the environment and return the node\/instance names.
--
-- This also hardcodes here the default node\/instance file names.
parseEnv :: () -> IO (String, String)
parseEnv () = do
  a <- getEnvDefault "HTOOLS_NODES" "nodes"
  b <- getEnvDefault "HTOOLS_INSTANCES" "instances"
  return (a, b)

-- | A shell script template for autogenerated scripts.
shTemplate :: String
shTemplate =
    printf "#!/bin/sh\n\n\
           \# Auto-generated script for executing cluster rebalancing\n\n\
           \# To stop, touch the file /tmp/stop-htools\n\n\
           \set -e\n\n\
           \check() {\n\
           \  if [ -f /tmp/stop-htools ]; then\n\
           \    echo 'Stop requested, exiting'\n\
           \    exit 0\n\
           \  fi\n\
           \}\n\n"

-- | External tool data loader from a variety of sources.
loadExternalData :: (EToolOptions a) =>
                    a
                 -> IO (Node.List, Instance.List, String)
loadExternalData opts = do
  (env_node, env_inst) <- parseEnv ()
  let nodef = if nodeSet opts then nodeFile opts
              else env_node
      instf = if instSet opts then instFile opts
              else env_inst
  input_data <-
      case masterName opts of
        "" -> Text.loadData nodef instf
        host -> Rapi.loadData host

  let ldresult = input_data >>= Loader.mergeData
  (loaded_nl, il, csf) <-
      (case ldresult of
         Ok x -> return x
         Bad s -> do
           printf "Error: failed to load data. Details:\n%s\n" s
           exitWith $ ExitFailure 1
      )
  let (fix_msgs, fixed_nl) = Loader.checkData loaded_nl il

  unless (null fix_msgs || silent opts) $ do
         putStrLn "Warning: cluster has inconsistent data:"
         putStrLn . unlines . map (\s -> printf "  - %s" s) $ fix_msgs

  return (fixed_nl, il, csf)
