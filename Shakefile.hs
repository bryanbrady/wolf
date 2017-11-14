#!/usr/bin/env stack
{- stack
    runghc
    --package shakers
 -}

{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Shake makefile for project.
--
import Development.Shakers

-- | Main entry point.
--
main :: IO ()
main = shakeMain $ do
  let pats =
        [ "stack*.yaml"
        , "Shakefile.hs"
        , "main//*.hs"
        , "src//*.hs"
        ]
      pats' = delete "stack*.yaml" pats

  -- | Haskell rules.
  --
  hsRules "." pats'

  -- | Cabal rules.
  --
  cabalRules "." "wolf.cabal"

  -- | Stack rules.
  --
  stackRules "." pats

  -- | sanity
  --
  fake "." pats "sanity" $ const $ do
    need [ "build-error" ]
    need [ "lint", "weed" ]

  -- | Default things to run.
  --
  want [ "sanity", "format" ]
