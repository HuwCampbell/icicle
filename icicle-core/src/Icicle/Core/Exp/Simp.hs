{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE PatternGuards     #-}
module Icicle.Core.Exp.Simp
     ( simp
     , simpX
     , simpP
     , deadX
     ) where

import           Icicle.Common.Value
import           Icicle.Common.Base
import           Icicle.Common.Exp              hiding (simp)
import           Icicle.Common.Exp.Simp.ANormal
import qualified Icicle.Common.Exp.Simp.Beta    as B
import qualified Icicle.Common.Exp.Prim.Minimal as Min
import           Icicle.Common.Fresh
import           Icicle.Common.Type
import           Icicle.Common.FixT
import qualified Icicle.Core.Exp                as C
import           Icicle.Core.Exp.Prim
import qualified Icicle.Core.Eval.Exp           as CE

import           P

import           Control.Lens.Plated            (transformM)
import           Control.Monad.Trans.Class      (lift)

import qualified Data.Set                       as Set
import           Data.Hashable                  (Hashable)

-- | Core Simplifier:
--   * a normal
--   * beta reduction
--   * constant folding fully applied primitives
--   * case of irrefutable case
--   * let unwinding
--   * irrefutable case reduction
--   * irrefutable case branches abstraction
simp :: (Hashable n, Eq n) => a -> C.Exp a n -> Fresh n (C.Exp a n)
simp a_fresh
  =   anormal a_fresh
  <=< fmap deadX
  .   fixpoint (allSimp a_fresh)

-- | Core Simplifier FixT loop.
allSimp :: (Hashable n, Eq n)
        => a -> C.Exp a n -> FixT (Fresh n) (C.Exp a n)
allSimp a_fresh
  =   caseOfScrutinisedCase a_fresh
  <=< transformM transformations
  .   B.beta

  where
    transformations
      =   simpX a_fresh
      >=> caseOfCase a_fresh
      >=> caseOfIrrefutable a_fresh
      >=> caseConstants a_fresh
      >=> unshuffleLets a_fresh

-- | Constant folding for some primitives
simpX :: (Monad m, Hashable n, Eq n)
             => a -> C.Exp a n -> FixT m (C.Exp a n)
simpX a_fresh xx
  | Just (prim, as) <- takePrimApps xx
  , Just args       <- mapM takeValue as
  , Just simplified <- simpP a_fresh prim args
  = progress simplified
  | otherwise
  = return xx

-- | Primitive Simplifier
simpP :: (Hashable n, Eq n) => a -> Prim -> [Value a n Prim] -> Maybe (C.Exp a n)
simpP a_fresh p vs
 | length (functionArguments $ C.typeOfPrim p) == length vs
 = case CE.evalPrim p vs of
    Right (VBase b)
     -> Just
      $ XValue a_fresh (functionReturns $ C.typeOfPrim p) b
    -- TODO: we could actually pull the
    -- heap out as let bindings, and so on..
    Right VFun{}
     -> Nothing
    Left _
     -> Nothing
 | otherwise
 = Nothing


-- | Dead binding removal
deadX :: Eq n => C.Exp a n -> C.Exp a n
deadX = fst . go
  where
    go xx = case xx of
      XApp a p q
        -> let (px, pf) = go p
               (qx, qf) = go q
           in  (XApp a px qx, Set.union pf qf)

      XLam a n t x1
        -> let (x1', fs) = go x1
           in  (XLam a n t x1', Set.delete n fs)

      XLet a n x1 x2
        -> let (x2', f2) = go x2
               (x1', f1) = go x1
           in  if   n `Set.member` f2
               then (XLet a n x1' x2', Set.union f1 f2)
               else (             x2',              f2)

      b@(XVar _ n) -> (b, Set.singleton n)
      b@XPrim {}   -> (b, Set.empty)
      b@XValue {}  -> (b, Set.empty)

-- | Case of Irrefutable Case.
caseOfCase :: (Hashable n, Eq n)
           => a -> C.Exp a n -> FixT (Fresh n) (C.Exp a n)
caseOfCase a_fresh xx
  | Just (primitive, as) <- takePrimApps xx
  , PrimFold _ ret'typ <- primitive
  , [XLam _ l'n _ l'exp, XLam _ r'n _ r'exp, scrut] <- as
  , Just (primitive', ass) <- takePrimApps scrut
  , PrimFold fld _ <- primitive'
  , [XLam _ i'l'n i'l'typ i'l'exp, XLam _ i'r'n i'r'typ i'r'exp, scrutinee] <- ass
  , Just (l'case, r'case) <- (,) <$> takeIrrefutable i'l'exp <*> takeIrrefutable i'r'exp
  = do
      n'l <- lift fresh
      n'r <- lift fresh

      let
        renameInLeft
          = subsNameInExp i'l'n n'l

        renameInRight
          = subsNameInExp i'r'n n'r

        replaceIn
          = either (const l'exp) (const r'exp)

        newLeftLam
          = xlam n'l i'l'typ
          $ xlet l'n (join either renameInLeft l'case) (replaceIn l'case)

        newRightLam
          = xlam n'r i'r'typ
          $ xlet r'n (join either renameInRight r'case) (replaceIn r'case)

      progress
        $ xprim (PrimFold fld ret'typ)
          `xapp` newLeftLam
          `xapp` newRightLam
          `xapp` scrutinee

  | otherwise
  = return xx
    where
  xapp = XApp a_fresh
  xprim = XPrim a_fresh
  xlet = XLet a_fresh
  xlam = XLam a_fresh

-- | If the case scrutinee is irrefutable,
--   replace the case expression with a let
--   binding.
caseOfIrrefutable :: (Monad m, Hashable n, Eq n)
                  => a -> C.Exp a n -> FixT m (C.Exp a n)
caseOfIrrefutable a_fresh xx
  | Just (PrimFold _ _, [XLam _ l'n _ l'exp, XLam _ r'n _ r'exp, scrut]) <- takePrimApps xx
  , Just scrut' <- takeIrrefutable scrut
  = case scrut' of
      Left x ->
        progress $
          xlet l'n x l'exp
      Right x ->
        progress $
          xlet r'n x r'exp

  | otherwise
  = return xx
    where
  xlet = XLet a_fresh

-- | Simplification when both sides of a fold
--   are wrapped with the same constructor.
--
--   By itself this doesn't do much, but it does
--   permit the case of case optimisation and has
--   no real cost itself.
caseConstants :: (Monad m, Hashable n, Eq n)
              => a -> C.Exp a n -> FixT m (C.Exp a n)
caseConstants a_fresh xx
  | Just (PrimFold a (SumT ret'l ret'r), [XLam _ l'n l'typ l'exp, XLam _ r'n r'typ r'exp, scrut]) <- takePrimApps xx
  , Just (l'side, r'side) <- (,) <$> takeIrrefutable l'exp <*> takeIrrefutable r'exp
  = case (l'side, r'side) of
      (Left x, Left y) ->
        progress $
          xapp (xleft ret'l ret'r)
          $ xprim (PrimFold a ret'l)
            `xapp` xlam l'n l'typ x
            `xapp` xlam r'n r'typ y
            `xapp` scrut
      (Right x, Right y) ->
        progress $
          xapp (xright ret'l ret'r)
          $ xprim (PrimFold a ret'r)
            `xapp` xlam l'n l'typ x
            `xapp` xlam r'n r'typ y
            `xapp` scrut
      _ -> return xx
  | otherwise
  = return xx
    where
  xapp = XApp a_fresh
  xprim = XPrim a_fresh
  xlam = XLam a_fresh
  xleft l r = xprim $ PrimMinimal (Min.PrimConst (Min.PrimConstLeft l r))
  xright l r = xprim $ PrimMinimal (Min.PrimConst (Min.PrimConstRight l r))

takeIrrefutable :: Exp a n Prim -> Maybe (Either (Exp a n Prim) (Exp a n Prim))
takeIrrefutable xx = case xx of
  XApp {}
    -> case takePrimApps xx of
        Just (prim, as)
          | PrimMinimal (Min.PrimConst Min.PrimConstRight {}) <- prim
          , [rhs] <- as
          -> Just (Right rhs)
          | PrimMinimal (Min.PrimConst Min.PrimConstLeft {}) <- prim
          , [lhs] <- as
          -> Just (Left lhs)
          | PrimMinimal (Min.PrimConst Min.PrimConstSome {}) <- prim
          , [real] <- as
          -> Just (Left real)
        _ -> Nothing

  XLam a n t x1
    -> XLam a n t <%> takeIrrefutable x1

  XLet a n p q
    -> XLet a n p <%> takeIrrefutable q

  XValue a (SumT t _ ) (VLeft x)  -> Just (Left  (XValue a t x))
  XValue a (SumT _ t ) (VRight x) -> Just (Right (XValue a t x))
  XValue a (OptionT t ) (VSome x) -> Just (Left  (XValue a t x))
  XValue a BoolT (VBool True)     -> Just (Left  (XValue a UnitT VUnit))
  XValue a BoolT (VBool False)    -> Just (Right (XValue a UnitT VUnit))
  XValue{} -> Nothing
  XVar{}   -> Nothing
  XPrim{}  -> Nothing
 where
  x <%> a = fmap (either (Left . x) (Right . x)) a

unshuffleLets :: (Monad m, Hashable n, Eq n)
              => a -> C.Exp a n -> FixT m (C.Exp a n)
unshuffleLets _ xx
  | XLet a n b q <- xx
  , XLet a1 n1 b1 x1 <- b
  = progress
    $ XLet a1 n1 b1
    $ XLet a n x1 q

  | otherwise
  = return xx

-- | If we've already scrutinised an expression, don't check it
--   again in either of its branches.
caseOfScrutinisedCase :: (Monad m, Hashable n, Eq n) => a -> C.Exp a n -> FixT m (C.Exp a n)
caseOfScrutinisedCase a_fresh = go []
  where
    go seen x = case x of
      XApp a p q
        | Just (fld@(PrimFold _ _), [XLam la lname ltyp lexp, XLam lb rname rtyp rexp, scrut]) <- takePrimApps x
        -> do lexp'  <- go ((scrut, Left lname) : seen) lexp
              rexp'  <- go ((scrut, Right rname) : seen) rexp
              case find (\(e,_) -> e `simpleEquality` scrut) seen of
                Just (_,replacement) ->
                  progress
                  $ either
                    (\n -> subsNameInExp lname n lexp')
                    (\n -> subsNameInExp rname n rexp')
                    replacement

                Nothing -> do
                  scrut' <- go seen scrut
                  return
                    $ xprim fld
                     `xapp` XLam la lname ltyp lexp'
                     `xapp` XLam lb rname rtyp rexp'
                     `xapp` scrut'

        | otherwise
        -> XApp a <$> go seen p <*> go seen q

      XLam a n t p
        -> XLam a n t <$> go seen p

      XLet a n p q ->
        XLet a n <$> go seen p <*> go seen q

      XVar {}   -> pure x
      XPrim {}  -> pure x
      XValue {} -> pure x

    xapp = XApp a_fresh
    xprim = XPrim a_fresh


subsNameInExp :: Eq n => Name n -> Name n -> Exp a n p -> Exp a n p
subsNameInExp old new =
  let worker m | m == old  = new
               | otherwise = m
  in renameExp worker
