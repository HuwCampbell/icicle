{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards#-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell#-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module Icicle.Test.Sea.Arbitrary where

import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.List as List

import           Icicle.Data (Entity(..), Attribute(..), AsAt(..))
import           Icicle.Data.Time (Time)

import qualified Icicle.Core.Program.Program as C
import qualified Icicle.Core.Program.Check as C

import qualified Icicle.Avalanche.Annot as A
import qualified Icicle.Avalanche.Check as A
import qualified Icicle.Avalanche.FromCore as A
import qualified Icicle.Avalanche.Prim.Flat as A
import qualified Icicle.Avalanche.Program as A
import qualified Icicle.Avalanche.Simp as A
import qualified Icicle.Avalanche.Statement.Flatten as A

import           Icicle.Common.Base
import           Icicle.Common.Type
import           Icicle.Common.Annot
import qualified Icicle.Common.Fresh as Fresh

import qualified Icicle.Sea.FromAvalanche.Analysis as S
import qualified Icicle.Sea.Eval as S

import           Icicle.Test.Arbitrary
import           Icicle.Test.Core.Arbitrary

import           P

import           Test.QuickCheck


newtype InputType = InputType {
    unInputType :: ValType
  } deriving (Show)

data WellTyped = WellTyped {
    wtEntities  :: [Entity]
  , wtAttribute :: Attribute
  , wtFactType  :: ValType
  , wtFacts     :: [AsAt BaseValue]
  , wtTime      :: Time
  , wtCore      :: C.Program ()         Var
  , wtAvalanche :: A.Program (Annot ()) Var A.Prim
  } deriving (Show)

instance Arbitrary InputType where
  arbitrary = validated 100 $ do
    ty <- arbitrary
    if isSupportedInput ty
       then pure . Just . inputTypeOf $ ty
       else pure Nothing

inputTypeOf :: ValType -> InputType
inputTypeOf ty
    = InputType $ SumT ErrorT ty

instance Arbitrary WellTyped where
  arbitrary = validated 10 (tryGenWellTypedWith S.DoNotAllowDupTime =<< arbitrary)

tryGenWellTypedWith :: S.PsvInputAllowDupTime -> InputType -> Gen (Maybe WellTyped)
tryGenWellTypedWith allowDupTime (InputType ty) = do
    entities       <- List.sort . List.nub . getNonEmpty <$> arbitrary
    attribute      <- arbitrary
    (inputs, time) <- case allowDupTime of
                        S.AllowDupTime
                          -> inputsForType ty
                        S.DoNotAllowDupTime
                          -> first (List.nubBy ((==) `on` atTime)) <$> inputsForType ty
    core           <- programForStreamType ty
    return $ do
      checked <- fromEither (C.checkProgram core)
      _       <- traverse (supportedOutput . functionReturns . snd) checked

      let avalanche = A.programFromCore namer core

      (_, flatStmts) <- fromEither (Fresh.runFreshT (A.flatten () (A.statements avalanche)) anfCounter)

      flattened <- fromEither (A.checkProgram A.flatFragment (replaceStmts avalanche flatStmts))

      let (_, unchecked) = Fresh.runFresh (A.simpFlattened dummyAnn flattened) simpCounter

      simplified <- fromEither (A.checkProgram A.flatFragment (A.eraseAnnotP unchecked))

      let types = Set.toList (S.typesOfProgram simplified)
      case filter (not . isSupportedType) types of
        []    -> Just ()
        (_:_) -> Nothing

      return WellTyped {
          wtEntities  = entities
        , wtAttribute = attribute
        , wtFactType  = ty
        , wtFacts     = fmap (fmap snd) inputs
        , wtTime      = time
        , wtCore      = core
        , wtAvalanche = simplified
        }
    where
      replaceStmts prog stms = prog { A.statements = stms }

      namer       = A.namerText (flip Var 0)
      dummyAnn    = Annot (FunT [] UnitT) ()
      anfCounter  = Fresh.counterNameState (NameBase . Var "anf")  0
      simpCounter = Fresh.counterNameState (NameBase . Var "simp") 0

      supportedOutput t | isSupportedOutput t = Just t
      supportedOutput _                       = Nothing


genWellTypedWithDuplicateTimes :: Gen WellTyped
genWellTypedWithDuplicateTimes
 = validated 10 (tryGenWellTypedWith S.AllowDupTime =<< arbitrary)

-- If the input are structs, we can pretend it's a dense value
-- We can't treat other values as a single-field dense struct because the
-- generated programs do not treat them as such.
genWellTypedWithStruct :: S.PsvInputAllowDupTime -> Gen WellTyped
genWellTypedWithStruct allowDupTime = validated 10 $ do
  st <- arbitrary :: Gen StructType
  tryGenWellTypedWith allowDupTime (inputTypeOf $ StructT st)

------------------------------------------------------------------------

validated :: Int -> Gen (Maybe a) -> Gen a
validated n g
  | n <= 0    = discard
  | otherwise = do
      m <- g
      case m of
        Nothing -> validated (n-1) g
        Just x  -> pure x

fromEither :: Either x a -> Maybe a
fromEither (Left _)  = Nothing
fromEither (Right x) = Just x

isSupportedInput :: ValType -> Bool
isSupportedInput = \case
  BoolT     -> True
  IntT      -> True
  DoubleT   -> True
  TimeT     -> True
  StringT   -> True

  UnitT     -> False
  ErrorT    -> False
  BufT{}    -> False
  MapT{}    -> False
  PairT{}   -> False
  SumT{}    -> False
  OptionT{} -> False

  ArrayT t
   -> isSupportedInputElem t

  StructT (StructType fs)
   | Map.null fs
   -> False
   | otherwise
   -> all isSupportedInputField (Map.elems fs)

isSupportedInputElem :: ValType -> Bool
isSupportedInputElem = \case
  BoolT     -> True
  IntT      -> True
  DoubleT   -> True
  TimeT     -> True
  StringT   -> True

  UnitT     -> False
  ErrorT    -> False
  ArrayT{}  -> False
  BufT{}    -> False
  MapT{}    -> False
  PairT{}   -> False
  SumT{}    -> False
  OptionT{} -> False

  StructT (StructType fs)
   -> all isSupportedInputField (Map.elems fs)

isSupportedInputField :: ValType -> Bool
isSupportedInputField = \case
  BoolT           -> True
  IntT            -> True
  DoubleT         -> True
  TimeT           -> True
  StringT         -> True
  OptionT BoolT   -> True
  OptionT IntT    -> True
  OptionT DoubleT -> True
  OptionT TimeT   -> True
  OptionT StringT -> True

  UnitT     -> False
  ErrorT    -> False
  ArrayT{}  -> False
  BufT{}    -> False
  MapT{}    -> False
  PairT{}   -> False
  SumT{}    -> False
  OptionT{} -> False

  StructT (StructType fs)
   -> all isSupportedInputField (Map.elems fs)

isSupportedOutput :: ValType -> Bool
isSupportedOutput = \case
  OptionT t              -> isSupportedOutputElem t
  PairT a b              -> isSupportedOutputElem a && isSupportedOutputElem b
  SumT ErrorT t          -> isSupportedOutputElem t

  ArrayT (ArrayT t)      -> isSupportedOutputElem t
  ArrayT t               -> isSupportedOutputElem t
  MapT k v               -> isSupportedOutputElem k && isSupportedOutputElem v

  t                      -> isSupportedOutputBase t

isSupportedOutputElem :: ValType -> Bool
isSupportedOutputElem = \case
  OptionT t              -> isSupportedOutputElem t
  PairT a b              -> isSupportedOutputElem a && isSupportedOutputElem b
  SumT ErrorT t          -> isSupportedOutputElem t

  ArrayT _               -> False
  MapT   _ _             -> False

  t                      -> isSupportedOutputBase t

isSupportedOutputBase :: ValType -> Bool
isSupportedOutputBase = \case
  BoolT     -> True
  IntT      -> True
  DoubleT   -> True
  TimeT     -> True
  StringT   -> True

  UnitT     -> False
  ErrorT    -> False
  BufT{}    -> False
  StructT{} -> False

  _         -> False

isSupportedType :: ValType -> Bool
isSupportedType = \case
  UnitT     -> True
  BoolT     -> True
  IntT      -> True
  DoubleT   -> True
  TimeT     -> True
  StringT   -> True
  ErrorT    -> True
  MapT{}    -> True
  PairT{}   -> True
  OptionT{} -> True
  StructT{} -> True
  SumT{}    -> True

  BufT _ t          -> not (isBufOrArray t)
  ArrayT (ArrayT t) -> not (isBufOrArray t)
  ArrayT (BufT _ t) -> not (isBufOrArray t)
  ArrayT t          -> not (isBufOrArray t)

isBufOrArray :: ValType -> Bool
isBufOrArray = \case
  BufT{}    -> True
  ArrayT{}  -> True
  _         -> False
