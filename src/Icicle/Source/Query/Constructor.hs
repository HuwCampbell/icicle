-- | Constructors, like Some, None, tuples etc
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE OverloadedStrings #-}
module Icicle.Source.Query.Constructor (
    Constructor (..)
  , Pattern (..)
  , substOfPattern
  , arityOfConstructor
  ) where

import                  Icicle.Common.Base
import                  Icicle.Internal.Pretty

import                  P

import qualified        Data.Map as Map

data Constructor
 -- Option
 = ConSome
 | ConNone

 -- ,
 | ConTuple

 -- Bool
 | ConTrue
 | ConFalse
 deriving (Eq, Ord, Show)

data Pattern n
 = PatCon Constructor [Pattern n]
 | PatDefault
 | PatVariable (Name n)
 deriving (Show, Eq, Ord)


substOfPattern :: Ord n => Pattern n -> BaseValue -> Maybe (Map.Map (Name n) BaseValue)
substOfPattern PatDefault _
 = return Map.empty
substOfPattern (PatVariable n) v
 = return (Map.singleton n v)

substOfPattern (PatCon ConSome pats) val
 | [pa]         <- pats
 , VSome va     <- val
 = substOfPattern pa va
 | otherwise
 = Nothing

substOfPattern (PatCon ConNone pats) val
 | []           <- pats
 , VNone        <- val
 = return Map.empty
 | otherwise
 = Nothing

substOfPattern (PatCon ConTuple pats) val
 | [pa, pb]     <- pats
 , VPair va vb  <- val
 = Map.union <$> substOfPattern pa va <*> substOfPattern pb vb
 | otherwise
 = Nothing

substOfPattern (PatCon ConTrue pats) val
 | []           <- pats
 , VBool True   <- val
 = return Map.empty
 | otherwise
 = Nothing

substOfPattern (PatCon ConFalse pats) val
 | []           <- pats
 , VBool False  <- val
 = return Map.empty
 | otherwise
 = Nothing


arityOfConstructor :: Constructor -> Int
arityOfConstructor cc
 = case cc of
    ConSome -> 1
    ConNone -> 0

    ConTuple -> 2

    ConTrue -> 0
    ConFalse -> 0

instance Pretty Constructor where
 pretty ConSome = "Some"
 pretty ConNone = "None"

 pretty ConTuple = "Tuple"

 pretty ConTrue = "True"
 pretty ConFalse = "False"


instance Pretty n => Pretty (Pattern n) where
 pretty (PatCon ConTuple [a,b])
  = "(" <> pretty a <> ", " <> pretty b <> ")"
 pretty (PatCon c [])
  = pretty c
 pretty (PatCon c vs)
  = "(" <> pretty c <> hsep (fmap pretty vs) <> ")"
 pretty PatDefault
  = "_"
 pretty (PatVariable n)
  = pretty n
