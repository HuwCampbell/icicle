{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE NoImplicitPrelude #-}
module Icicle.Source.ToCore.Prim (
    convertPrim
  ) where

import                  Icicle.Source.Query
import                  Icicle.Source.ToCore.Base
import                  Icicle.Source.Type

import qualified        Icicle.Core as C
import qualified        Icicle.Core.Exp.Combinators as CE
import qualified        Icicle.Common.Base          as V
import qualified        Icicle.Common.Exp           as CE
import qualified        Icicle.Common.Type          as T
import qualified        Icicle.Common.Fresh         as F

import qualified        Icicle.Common.Exp.Prim.Minimal as Min

import                  P

import                  Control.Monad.Trans.Class
import                  Data.Hashable


-- | Convert a primitive application.
-- All the arguments are already converted, so we just need to
-- look up the new primitive and apply the converted arguments.
--
-- This only works for *expression* primitives, not aggregates.
-- Aggregates must be handled earlier.
-- If they show up here it means a type error, for example
-- an aggregate in a filter expression:
--
-- > filter sum(value) > 5
--
-- is ill typed.
convertPrim
        :: (Hashable n)
        => Prim -> a
        -> Type n
        -> [(C.Exp () n, Type n)]
        -> ConvertM a n (C.Exp () n)
convertPrim p ann resT xts = go p
 where
  args       = fmap fst xts
  applies p' = CE.makeApps () p' args

  primmin p'  = applies $ CE.XPrim () $ C.PrimMinimal p'
  primbuiltin = primmin . Min.PrimBuiltinFun

  t1 num_args
   = case xts of
      ((_,tt):_) -> convertValType ann tt
      []         -> convertError
                  $ ConvertErrorPrimNoArguments ann num_args p

  tArithArg num_args
   = do t' <- t1 num_args
        case T.arithTypeOfValType t' of
         Nothing -> convertError $ ConvertErrorPrimNoArguments ann num_args p
         Just a' -> return a'


  -- Literals
  go (Lit (LitInt i))
   | (_, _, DoubleT) <- decomposeT resT
   = return $ CE.XValue () T.DoubleT (V.VDouble $ fromIntegral i)
   | otherwise
   = return $ CE.constI i
  go (Lit (LitDouble i))
   = return $ CE.XValue () T.DoubleT (V.VDouble i)
  go (Lit (LitString i))
   = return $ CE.XValue () T.StringT (V.VString i)
  go (Lit (LitTime i))
   = return $ CE.XValue () T.TimeT (V.VTime i)

  -- Constructors
  go (PrimCon ConSome)
   = primmin <$> (Min.PrimConst <$> (Min.PrimConstSome <$> t1 1))
  go (PrimCon ConNone)
   = flip (CE.XValue ()) V.VNone <$> convertValType ann resT
  go (PrimCon ConTuple)
   = go $ Op TupleComma
  go (PrimCon ConTrue)
   = return $ CE.XValue () T.BoolT $ V.VBool True
  go (PrimCon ConFalse)
   = return $ CE.XValue () T.BoolT $ V.VBool False
  go (PrimCon ConLeft)
   | (_, _, SumT a b) <- decomposeT resT
   = do a' <- convertValType ann a
        b' <- convertValType ann b
        return $ primmin $ Min.PrimConst $ Min.PrimConstLeft a' b'
   | otherwise
   = convertError
   $ ConvertErrorPrimNoArguments ann 2 p
  go (PrimCon ConRight)
   | (_, _, SumT a b) <- decomposeT resT
   = do a' <- convertValType ann a
        b' <- convertValType ann b
        return $ primmin $ Min.PrimConst $ Min.PrimConstRight a' b'
   | otherwise
   = convertError
   $ ConvertErrorPrimNoArguments ann 2 p
  go (PrimCon (ConError err))
   = return $ CE.XValue () T.ErrorT $ V.VError err

  go (Fun (BuiltinMath f))
   = gomath f
  go (Fun (BuiltinTime f))
   = gotime f
  go (Fun (BuiltinData f))
   = godata f
  go (Fun (BuiltinMap f))
   = gomap f
  go (Fun (BuiltinArray f))
   = goarray f

  go (Op o)
   = goop o


  -- Arithmetic
  goop (ArithUnary Negate)
   = primmin <$> (Min.PrimArithUnary Min.PrimArithNegate <$> tArithArg 1)
  goop (ArithBinary Add)
   = primmin <$> (Min.PrimArithBinary Min.PrimArithPlus <$> tArithArg 2)
  goop (ArithBinary Sub)
   = primmin <$> (Min.PrimArithBinary Min.PrimArithMinus <$> tArithArg 2)
  goop (ArithBinary Mul)
   = primmin <$> (Min.PrimArithBinary Min.PrimArithMul <$> tArithArg 2)
  goop (ArithBinary Pow)
   = primmin <$> (Min.PrimArithBinary Min.PrimArithPow <$> tArithArg 2)
  goop (ArithDouble Div)
   = return $ primbuiltin $ Min.PrimBuiltinMath Min.PrimBuiltinDiv

  -- Logic
  goop (LogicalUnary Not)
   = return $ primmin $ Min.PrimLogical Min.PrimLogicalNot
  goop (LogicalBinary And)
   = return $ primmin $ Min.PrimLogical Min.PrimLogicalAnd
  goop (LogicalBinary Or)
   = return $ primmin $ Min.PrimLogical Min.PrimLogicalOr

  -- Time
  goop (TimeBinary DaysBefore)
   | [(a,_),(b,_)] <- xts
   = return (CE.xPrim (C.PrimMinimal $ Min.PrimTime Min.PrimTimeMinusDays) CE.@~ b CE.@~ a)
   | otherwise
   = convertError
   $ ConvertErrorPrimNoArguments ann 2 p
  goop (TimeBinary WeeksBefore)
   | [(a,_),(b,_)] <- xts
   = return (CE.xPrim (C.PrimMinimal $ Min.PrimTime Min.PrimTimeMinusDays) CE.@~ b CE.@~ (CE.constI 7 CE.*~ a))
   | otherwise
   = convertError
   $ ConvertErrorPrimNoArguments ann 2 p
  goop (TimeBinary MonthsBefore)
   | [(a,_),(b,_)] <- xts
   = return (CE.xPrim (C.PrimMinimal $ Min.PrimTime Min.PrimTimeMinusMonths) CE.@~ b CE.@~ a)
   | otherwise
   = convertError
   $ ConvertErrorPrimNoArguments ann 2 p
  goop (TimeBinary DaysAfter)
   | [(a,_),(b,_)] <- xts
   = return (CE.xPrim (C.PrimMinimal $ Min.PrimTime Min.PrimTimeMinusDays) CE.@~ b CE.@~ (CE.negate a))
   | otherwise
   = convertError
   $ ConvertErrorPrimNoArguments ann 2 p
  goop (TimeBinary WeeksAfter)
   | [(a,_),(b,_)] <- xts
   = return (CE.xPrim (C.PrimMinimal $ Min.PrimTime Min.PrimTimeMinusDays) CE.@~ b CE.@~ (CE.negate (CE.constI 7 CE.*~ a)))
   | otherwise
   = convertError
   $ ConvertErrorPrimNoArguments ann 2 p
  goop (TimeBinary MonthsAfter)
   | [(a,_),(b,_)] <- xts
   = return (CE.xPrim (C.PrimMinimal $ Min.PrimTime Min.PrimTimeMinusMonths) CE.@~ b CE.@~ (CE.negate a))
   | otherwise
   = convertError
   $ ConvertErrorPrimNoArguments ann 2 p

  -- Relation
  goop (Relation Gt)
   = primmin <$> (Min.PrimRelation Min.PrimRelationGt <$> t1 2)
  goop (Relation Ge)
   = primmin <$> (Min.PrimRelation Min.PrimRelationGe <$> t1 2)
  goop (Relation Lt)
   = primmin <$> (Min.PrimRelation Min.PrimRelationLt <$> t1 2)
  goop (Relation Le)
   = primmin <$> (Min.PrimRelation Min.PrimRelationLe <$> t1 2)
  goop (Relation Eq)
   = primmin <$> (Min.PrimRelation Min.PrimRelationEq <$> t1 2)
  goop (Relation Ne)
   = primmin <$> (Min.PrimRelation Min.PrimRelationNe <$> t1 2)

  goop TupleComma
   | [(_,a),(_,b)] <- xts
   = do a' <- convertValType ann a
        b' <- convertValType ann b
        return $ primmin $ Min.PrimConst $ Min.PrimConstPair a' b'

   | otherwise
   = convertError
   $ ConvertErrorPrimNoArguments ann 2 p


  -- Source built-in primitives supported by other language fragments
  gotime DaysBetween
   = return $ primmin $ Min.PrimTime Min.PrimTimeDaysDifference
  gotime DaysEpoch
   = return $ primmin $ Min.PrimTime Min.PrimTimeDaysEpoch
  -- This looks pointless, but actually isn't. Reify possibilities takes care of sequencing both
  -- of the possiblities of this function, so although we don't check that the first tuple is
  -- not a tombstone here, it is now assured to not be.
  godata Seq
   | [_,(xb,_)] <- xts
   = return xb
   | otherwise
   = convertError
   $ ConvertErrorPrimNoArguments ann 2 p
  -- Similarly this is not a tombstone.
  godata Box
   | [(x,_)] <- xts
   = return x
   | otherwise
   = convertError
   $ ConvertErrorPrimNoArguments ann 1 p


  -- Source built-in primitives that map to common built-ins.
  gomath Log
   = return $ primbuiltin $ Min.PrimBuiltinMath Min.PrimBuiltinLog
  gomath Exp
   = return $ primbuiltin $ Min.PrimBuiltinMath Min.PrimBuiltinExp
  gomath Sqrt
   = return $ primbuiltin $ Min.PrimBuiltinMath Min.PrimBuiltinSqrt

  gomath Abs
   = case xts of
      ((_,tt):_)
       | (_, _, DoubleT) <- decomposeT tt
       -> return $ primmin $ Min.PrimArithUnary Min.PrimArithAbsolute T.ArithDoubleT
      ((_,tt):_)
       | (_, _, IntT) <- decomposeT tt
       -> return $ primmin $ Min.PrimArithUnary Min.PrimArithAbsolute T.ArithIntT
      _
       -> convertError $ ConvertErrorPrimNoArguments ann 1 p
  gomath ToDouble
   = case xts of
      ((xx,tt):_)
       | (_, _, DoubleT) <- decomposeT tt
       -> return xx
      _
       -> return $ primbuiltin $ Min.PrimBuiltinMath Min.PrimBuiltinToDoubleFromInt
  gomath Floor
   = case xts of
      ((xx,tt):_)
       | (_, _, IntT) <- decomposeT tt
       -> return xx
      _
       -> return $ primbuiltin $ Min.PrimBuiltinMath Min.PrimBuiltinFloor
  gomath Ceiling
   = case xts of
      ((xx,tt):_)
       | (_, _, IntT) <- decomposeT tt
       -> return xx
      _
       -> return $ primbuiltin $ Min.PrimBuiltinMath Min.PrimBuiltinCeiling
  gomath Round
   = case xts of
      ((xx,tt):_)
       | (_, _, IntT) <- decomposeT tt
       -> return xx
      _
       -> return $ primbuiltin $ Min.PrimBuiltinMath Min.PrimBuiltinRound
  gomath Truncate
   = case xts of
      ((xx,tt):_)
       | (_, _, IntT) <- decomposeT tt
       -> return xx
      _
       -> return $ primbuiltin $ Min.PrimBuiltinMath Min.PrimBuiltinTruncate

  gomap MapKeys
   | ((_, tm) : _) <- xts
   = case valTypeOfType tm of
       Just (T.MapT k v)
         -> return $ primbuiltin $ Min.PrimBuiltinMap $ Min.PrimBuiltinKeys k v
       _ -> convertError $ ConvertErrorCannotConvertType ann tm
   | otherwise
   = convertError $ ConvertErrorPrimNoArguments ann 1 p
  gomap MapValues
   | ((_, tm) : _) <- xts
   = case valTypeOfType tm of
       Just (T.MapT k v)
         -> return $ primbuiltin $ Min.PrimBuiltinMap $ Min.PrimBuiltinVals k v
       _ -> convertError $ ConvertErrorCannotConvertType ann tm
   | otherwise
   = convertError $ ConvertErrorPrimNoArguments ann 1 p
  gomap MapCreate
   | Just (T.MapT tk tv) <- valTypeOfType resT
   = return $ CE.emptyMap tk tv
   | otherwise
   = convertError $ ConvertErrorCannotConvertType ann resT
  gomap MapInsert
   | ((xk, _) : (xv, _) : (xm, tm) : _) <- xts
   = case valTypeOfType tm of
       Just (T.MapT tk tv)
         -> do n <- lift F.fresh
               return $ CE.makeApps ()
                        (CE.XPrim () . C.PrimMap $ C.PrimMapInsertOrUpdate tk tv)
                        [CE.XLam () n tv xv, xv, xk, xm]
       _ -> convertError $ ConvertErrorCannotConvertType ann tm
   | otherwise
   = convertError $ ConvertErrorPrimNoArguments ann 3 p
  gomap MapDelete
   | (_ : _ : (_, tm) : _) <- xts
   = case valTypeOfType tm of
       Just (T.MapT tk tv)
         -> return $ applies $ CE.XPrim () $ C.PrimMap $ C.PrimMapDelete tk tv
       _ -> convertError $ ConvertErrorCannotConvertType ann tm
   | otherwise
   = convertError $ ConvertErrorPrimNoArguments ann 2 p
  gomap MapLookup
   | ((k, _) : (m, tm) : as) <- xts
   = case valTypeOfType tm  of
       Just (T.MapT tk tv)
         -> return
          $ CE.makeApps () (CE.XPrim () $ C.PrimMap $ C.PrimMapLookup tk tv)
                           (m : k : fmap fst as)
       _ -> convertError $ ConvertErrorCannotConvertType ann tm
   | otherwise
   = convertError $ ConvertErrorPrimNoArguments ann 2 p

  goarray ArraySort
   | ((_, ta) : _) <- xts
   = goarray' ta Min.PrimBuiltinSort
   | otherwise
   = convertError $ ConvertErrorPrimNoArguments ann 1 p
  goarray ArrayLength
   | ((_, ta) : _) <- xts
   = goarray' ta Min.PrimBuiltinLength
   | otherwise
   = convertError $ ConvertErrorPrimNoArguments ann 1 p
  goarray ArrayIndex
   | ((_, ta) : _ : _) <- xts
   = goarray' ta Min.PrimBuiltinIndex
   | otherwise
   = convertError $ ConvertErrorPrimNoArguments ann 2 p

  goarray' tt prim
   | Just (T.ArrayT t) <- valTypeOfType tt
   = return $ primbuiltin $ Min.PrimBuiltinArray $ prim t
   | otherwise
   = convertError $ ConvertErrorCannotConvertType ann tt
