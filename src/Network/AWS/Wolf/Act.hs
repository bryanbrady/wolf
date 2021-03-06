{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

-- | SWF Actor logic.
--
module Network.AWS.Wolf.Act
  ( act
  , actMain
  ) where

import Data.Aeson
import Data.Time
import Network.AWS.Wolf.Ctx
import Network.AWS.Wolf.File
import Network.AWS.Wolf.Prelude
import Network.AWS.Wolf.SWF
import Network.AWS.Wolf.Types
import System.Directory
import System.Exit
import System.Process

-- | S3 copy call.
--
cp :: MonadIO m => [FilePath] -> m ()
cp = liftIO . callProcess "aws" . (["s3", "sync", "--quiet"] <>)

-- | Key to download and upload objects from.
--
key :: MonadAmazonStore c m => m FilePath
key = do
  b <- view cBucket <$> view ccConf
  p <- view ascPrefix
  pure $ "s3:/" -/- textToString b -/- textToString p

-- | Download artifacts to the store input directory.
--
download :: MonadAmazonStore c m => FilePath -> [FilePath] -> m ()
download dir includes = do
  traceInfo "download" [ "dir" .= dir, "includes" .= includes ]
  let includes' = bool ([ "--exclude", "*" ] <> interleave (repeat "--include") includes) mempty $ null includes
  k <- key
  cp $ includes' <> [ k, dir ]

-- | Upload artifacts from the store output directory.
--
upload :: MonadAmazonStore c m => FilePath -> m ()
upload dir = do
  traceInfo "upload" [ "dir" .= dir ]
  k <- key
  cp [ dir, k ]

-- | callCommand wrapper that maybe returns an exception.
--
callCommand' :: MonadControl m => String -> m (Maybe SomeException)
callCommand' command =
  handle (pure . Just) $ do
    liftIO $ callCommand command
    pure Nothing

-- | Run command and maybe returns an exception.
--
run :: MonadStatsCtx c m => String -> m (Maybe SomeException)
run command =
  preCtx [ "command" .= command ] $ do
    traceInfo "begin" mempty
    e <- callCommand' command
    traceInfo "end" [ "exception" .= (displayException <$> e) ]
    pure e

-- | Check if quiesce file is present.
--
check :: MonadIO m => Maybe FilePath -> m Bool
check = maybe (pure False) (liftIO . doesFileExist)

-- | Actor logic - poll for work, download artifacts, run command, upload artifacts.
--
act :: MonadConf c m => Text -> Bool -> Bool -> [FilePath] -> String -> m ()
act queue nocopy local includes command =
  preConfCtx [ "label" .= LabelAct ] $
    runAmazonWorkCtx queue $ do
      traceInfo "poll" mempty
      t0 <- liftIO getCurrentTime
      (token, uid, input) <- pollActivity
      t1 <- liftIO getCurrentTime
      statsIncrement "wolf.act.poll.count" [ "queue" =. queue ]
      statsHistogram "wolf.act.poll.elapsed" (realToFrac (diffUTCTime t1 t0) :: Double) [ "queue" =. queue ]
      maybe_ token $ \token' ->
        maybe_ uid $ \uid' ->
          withCurrentWorkDirectory uid' nocopy local $ \wd ->
            runAmazonStoreCtx uid' $ do
              traceInfo "start" [ "dir" .= wd ]
              t2  <- liftIO getCurrentTime
              dd  <- dataDirectory wd
              sd  <- storeDirectory wd
              isd <- inputDirectory sd
              osd <- outputDirectory sd
              msd <- metaDirectory sd
              writeJson (dd </> "control.json") (Control uid')
              writeText (dd </> "input.json") input
              writeText (msd </> (textToString queue <> "_input.json")) input
              download isd includes
              e <- run command
              upload osd
              output <- readText (dd </> "output.json")
              writeText (msd </> (textToString queue <> "_output.json")) output
              maybe (completeActivity token' output) (const $ failActivity token') e
              t3 <- liftIO getCurrentTime
              traceInfo "finish" [ "dir" .= wd ]
              let status = textFromString $ maybe "complete" (const "fail") e
              statsIncrement "wolf.act.activity.count" [ "queue" =. queue, "status" =. status ]
              statsHistogram "wolf.act.activity.elapsed" (realToFrac (diffUTCTime t3 t2) :: Double) [ "queue" =. queue ]

-- | Run actor from main with config file.
--
actMain :: MonadControl m => FilePath -> Maybe FilePath -> Maybe Text -> Maybe Text -> Maybe Text -> Text -> Int -> Bool -> Bool -> [FilePath] -> String -> m ()
actMain cf quiesce domain bucket prefix queue num nocopy local includes command =
  runCtx $ runTop $ do
    conf <- readYaml cf
    let conf' = override cPrefix prefix $ override cBucket bucket $ override cDomain domain conf
    runConfCtx conf' $
      runConcurrent $ replicate num $ forever $ do
        ok <- check quiesce
        when ok $
          liftIO exitSuccess
        act queue nocopy local includes command
