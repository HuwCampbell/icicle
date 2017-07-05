{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PatternSynonyms #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}
module Icicle.Runtime.Data.Primitive (
    Unit64(..)
  , Bool64(..)
  , Time64(..)
  , Error64(..)

  , Field(..)

  , unit

  , pattern False64
  , pattern True64
  , fromBool
  , fromBool64

  , pattern NotAnError64
  , pattern Tombstone64
  , pattern Fold1NoValue64
  , pattern CannotCompute64
  , fromExceptionInfo
  , fromError64
  , isError
  ) where

import           Data.Word (Word64)

import           Foreign.Storable (Storable)

import           GHC.Generics (Generic)

import           Icicle.Common.Base (ExceptionInfo(..))

import           P

import           X.Text.Show (gshowsPrec)


--
-- NOTE: iint_t and idouble_t are not defined here as they are represented on
-- the Haskell side by Int64 and Double, respectively.
--

-- | The @iunit_t@ runtime type.
--
newtype Unit64 =
  Unit64 {
      unUnit64 :: Word64
    } deriving (Eq, Ord, Generic, Storable)

instance Show Unit64 where
  showsPrec =
    gshowsPrec

-- | The @ibool_t@ runtime type.
--
newtype Bool64 =
  Bool64 {
      unBool64 :: Word64
    } deriving (Eq, Ord, Generic, Storable)

instance Show Bool64 where
  showsPrec =
    gshowsPrec

-- | The @itime_t@ runtime type.
--
newtype Time64 =
  Time64 {
      unTime64 :: Word64
    } deriving (Eq, Ord, Generic, Storable)

instance Show Time64 where
  showsPrec =
    gshowsPrec

-- | The @ierror_t@ runtime type.
--
newtype Error64 =
  Error64 {
      unError64 :: Word64
    } deriving (Eq, Ord, Generic, Storable)

instance Show Error64 where
  showsPrec =
    gshowsPrec

-- | A named struct field.
--
data Field a =
  Field {
      fieldName :: !Text
    , fieldData :: !a
    } deriving (Eq, Ord, Generic, Functor, Foldable, Traversable)

instance Show a => Show (Field a) where
  showsPrec =
    gshowsPrec

unit :: Unit64
unit =
  Unit64 0x1C31C13
{-# INLINE unit #-}

#if __GLASGOW_HASKELL__ >= 800
pattern False64 :: Bool64
#endif
pattern False64 =
  Bool64 0

#if __GLASGOW_HASKELL__ >= 800
pattern True64 :: Bool64
#endif
pattern True64 =
  Bool64 1

fromBool :: Bool -> Bool64
fromBool = \case
  False ->
    False64
  True ->
    True64
{-# INLINE fromBool #-}

fromBool64 :: Bool64 -> Bool
fromBool64 = \case
  False64 ->
    False
  _ ->
    True
{-# INLINE fromBool64 #-}

#if __GLASGOW_HASKELL__ >= 800
pattern NotAnError64 :: Error64
#endif
pattern NotAnError64 =
  Error64 0

#if __GLASGOW_HASKELL__ >= 800
pattern Tombstone64 :: Error64
#endif
pattern Tombstone64 =
  Error64 1

#if __GLASGOW_HASKELL__ >= 800
pattern Fold1NoValue64 :: Error64
#endif
pattern Fold1NoValue64 =
  Error64 2

#if __GLASGOW_HASKELL__ >= 800
pattern CannotCompute64 :: Error64
#endif
pattern CannotCompute64 =
  Error64 2

fromExceptionInfo :: ExceptionInfo -> Error64
fromExceptionInfo = \case
  ExceptNotAnError ->
    NotAnError64
  ExceptTombstone ->
    Tombstone64
  ExceptFold1NoValue ->
    Fold1NoValue64
  ExceptCannotCompute ->
    CannotCompute64
{-# INLINE fromExceptionInfo #-}

isError :: Error64 -> Bool
isError = \case
  NotAnError64 ->
    False
  _ ->
    True
{-# INLINE isError #-}

fromError64 :: Error64 -> Maybe ExceptionInfo
fromError64 = \case
  NotAnError64 ->
    Just ExceptNotAnError
  Tombstone64 ->
    Just ExceptTombstone
  Fold1NoValue64 ->
    Just ExceptFold1NoValue
  CannotCompute64 ->
    Just ExceptCannotCompute
  _ ->
    Nothing
{-# INLINE fromError64 #-}
