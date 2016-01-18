-- | Fusing programs together
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PatternGuards #-}
module Icicle.Core.Program.Fusion (
    FusionError (..)
  , fusePrograms
  , fuseMultiple
  ) where

import Icicle.Common.Base
import Icicle.Common.Type
import Icicle.Core.Program.Program
import Icicle.Core.Program.Subst

import              P

data FusionError n
 = FusionErrorNotSameType ValType ValType
 | FusionErrorNothingToFuse
 deriving (Show)


-- | Fuse programs together, prefixing each with its name to ensure that the
-- generated program has no name clashes.
-- The two names must be distinct.
fusePrograms :: Ord n => a -> n -> Program a n -> n -> Program a n -> Either (FusionError n) (Program a n)
fusePrograms a_fresh ln lp rn rp
 = fuseProgramsDistinctNames a_fresh (prefix ln lp) (prefix rn rp)
 where
  prefix n = renameProgram (NameMod n)


-- | Fuse programs together, assuming they already have no name clashes.
fuseProgramsDistinctNames :: Ord n => a -> Program a n -> Program a n -> Either (FusionError n) (Program a n)
fuseProgramsDistinctNames _ lp rp
 | inputType lp /= inputType rp
 = Left
 $ FusionErrorNotSameType (inputType lp) (inputType rp)
 | otherwise
 = return
 $ Program
 { inputName = inputName lp
 , inputType = inputType lp
 , snaptimeName = snaptimeName lp
 , precomps  = precomps  lp <> substSnds (precomps  rp)
 , streams   = streams   lp <> substStms (streams   rp)
 , postcomps = postcomps lp <> substSnds (postcomps rp)
 , returns   = returns   lp <> substSnds (returns   rp)
 }
 where
  substSnds = unsafeSubstSnds    inpsubst
  substStms = unsafeSubstStreams inpsubst

  inpsubst
   = [ (inputName    rp, inputName    lp)
     , (snaptimeName rp, snaptimeName lp) ]


-- | Fuse a list of programs together, prefixing each with its name
fuseMultiple :: Ord n => a -> [(n, Program a n)] -> Either (FusionError n) (Program a n)
fuseMultiple a_fresh ps
 = let ps' = fmap (\(n,p) -> renameProgram (NameMod n) p) ps
   in  case ps' of
        [] -> Left FusionErrorNothingToFuse
        (f:fs) -> foldM (fuseProgramsDistinctNames a_fresh) f fs
