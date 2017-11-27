{-# LANGUAGE ConstraintKinds   #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Local Prelude.
--
module Network.AWS.Wolf.Prelude
  ( module Exports
  , runConcurrent
  ) where

import Control.Concurrent.Async.Lifted
import Preamble                        as Exports hiding (stripPrefix)

-- | Run a list of actions concurrently.
--
runConcurrent :: MonadBaseControl IO m => [m a] -> m ()
runConcurrent = void . runConcurrently . traverse Concurrently
