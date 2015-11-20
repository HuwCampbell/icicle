{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
module Icicle.Sea.FromAvalanche.Psv (
    PsvConfig(..)
  , seaOfPsvDriver
  ) where

import qualified Data.ByteString as B
import qualified Data.List as List
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Data.Word (Word8)
import           Data.Char

import           Icicle.Avalanche.Prim.Flat (Prim(..), PrimUpdate(..), PrimUnsafe(..))
import           Icicle.Avalanche.Prim.Flat (meltType)

import           Icicle.Common.Base (OutputName(..))
import           Icicle.Common.Type (ValType(..), StructType(..), StructField(..))
import           Icicle.Common.Type (defaultOfType)

import           Icicle.Data (Attribute(..), DateTime)

import           Icicle.Internal.Pretty
import qualified Icicle.Internal.Pretty as Pretty

import           Icicle.Sea.Error (SeaError(..))
import           Icicle.Sea.FromAvalanche.Base (seaOfDate, seaOfAttributeDesc)
import           Icicle.Sea.FromAvalanche.Base (seaOfNameIx, seaOfEscaped)
import           Icicle.Sea.FromAvalanche.Prim
import           Icicle.Sea.FromAvalanche.Program (seaOfXValue)
import           Icicle.Sea.FromAvalanche.State
import           Icicle.Sea.FromAvalanche.Type

import           P

import           Text.Printf (printf)


------------------------------------------------------------------------

data PsvConfig = PsvConfig {
    psvSnapshotDate :: DateTime
  , psvTombstones   :: Map Attribute (Set Text)
  } deriving (Eq, Ord, Show)

------------------------------------------------------------------------

seaOfPsvDriver :: [SeaProgramState] -> PsvConfig -> Either SeaError Doc
seaOfPsvDriver states config = do
  let struct_sea    = seaOfFleetState   states
      alloc_sea     = seaOfAllocFleet   states config
      collect_sea   = seaOfCollectFleet states
  read_sea  <- seaOfReadAnyFact      states config
  write_sea <- seaOfWriteFleetOutput states
  pure $ vsep
    [ struct_sea
    , ""
    , alloc_sea
    , ""
    , collect_sea
    , ""
    , read_sea
    , ""
    , write_sea
    ]

------------------------------------------------------------------------

seaOfFleetState :: [SeaProgramState] -> Doc
seaOfFleetState states
 = vsep
 [ "#line 1 \"fleet state\""
 , "struct ifleet {"
 , indent 4 (defOfVar 0 DateTimeT "snapshot_date;")
 , indent 4 (vsep (fmap defOfProgramState states))
 , "};"
 ]

defOfProgramState :: SeaProgramState -> Doc
defOfProgramState state
 = defOfVar' 0 (pretty (nameOfStateType state))
               (pretty (nameOfProgram state)) <> ";"
 <+> "/* " <> seaOfAttributeDesc (stateAttribute state) <> " */"

------------------------------------------------------------------------

seaOfAllocFleet :: [SeaProgramState] -> PsvConfig -> Doc
seaOfAllocFleet states config
 = vsep
 [ "#line 1 \"allocate fleet state\""
 , "static ifleet_t * psv_alloc_fleet ()"
 , "{"
 , "    idate_t date = " <> seaOfDate (psvSnapshotDate config) <> ";"
 , ""
 , "    ifleet_t *fleet = calloc (1, sizeof (ifleet_t));"
 , "    fleet->snapshot_date = date;"
 , ""
 , indent 4 (vsep (fmap seaOfAllocProgram states))
 , "    return fleet;"
 , "}"
 ]

seaOfAllocProgram :: SeaProgramState -> Doc
seaOfAllocProgram state
 = let ps        = "fleet->" <> pretty (nameOfProgram state) <> "."
       go (n, t) = ps <> pretty (newPrefix <> n) <> " = "
                <> "calloc (psv_max_row_count, sizeof (" <> seaOfValType t <> "));"

   in vsep [ "/* " <> seaOfAttributeDesc (stateAttribute state) <> " */"
           , ps <> pretty (stateDateVar state) <> " = date;"
           , vsep (fmap go (stateInputVars state))
           , ""
           ]

------------------------------------------------------------------------

seaOfCollectFleet :: [SeaProgramState] -> Doc
seaOfCollectFleet states
 = vsep
 [ "#line 1 \"collect fleet state\""
 , "static void psv_collect_fleet (ifleet_t *fleet)"
 , "{"
 , "    imempool_t *into_pool = imempool_create ();"
 , "    imempool_t *last_pool = 0;"
 , ""
 , indent 4 (vsep (fmap seaOfCollectProgram states))
 , ""
 , "    if (last_pool != 0) {"
 , "        imempool_free(last_pool);"
 , "    }"
 , "}"
 ]

seaOfCollectProgram :: SeaProgramState -> Doc
seaOfCollectProgram state
 = let ps    = "fleet->" <> pretty (nameOfProgram state) <> "."
       new n = ps <> pretty (newPrefix <> n)
       res n = ps <> pretty (resPrefix <> n)

       copyInputs nts
        = let docs = concatMap copyInput (stateInputVars state)
          in if List.null docs
             then []
             else [ "iint_t new_count = " <> ps <> "new_count;"
                  , "for (iint_t ix = 0; ix < new_count; ix++) {"
                  , indent 4 $ vsep $ concatMap copyInput nts
                  , "}"
                  ]

       copyInput (n, t)
        | not (needsCopy t)
        = []

        | otherwise
        = [ new n <> "[ix] = " <> prefixOfValType t <> "copy (into_pool, " <> new n <> "[ix]);" ]

       copyResumable (n, t)
        | not (needsCopy t)
        = []

        | otherwise
        = [ ""
          , "if (" <> ps <> pretty (hasPrefix <> n) <> ") {"
          , indent 4 (res n <> " = " <> prefixOfValType t <> "copy (into_pool, " <> res n <> ");")
          , "}"
          ]

   in vsep [ "/* " <> seaOfAttributeDesc (stateAttribute state) <> " */"
           , "last_pool = " <> ps <> "mempool;"
           , "if (last_pool != 0) {"
           , indent 4 $ vsep $ copyInputs (stateInputVars state)
                            <> concatMap copyResumable (stateResumables state)
           , "}"
           , ps <> "mempool = into_pool;"
           , ""
           ]

needsCopy :: ValType -> Bool
needsCopy = \case
  StringT   -> True
  ArrayT{}  -> True
  BufT{}    -> True

  UnitT     -> False
  BoolT     -> False
  IntT      -> False
  DoubleT   -> False
  DateTimeT -> False
  ErrorT    -> False

  -- these should have been melted
  PairT{}   -> False
  OptionT{} -> False
  StructT{} -> False
  SumT{}    -> False
  MapT{}    -> False

------------------------------------------------------------------------

seaOfReadAnyFact :: [SeaProgramState] -> PsvConfig -> Either SeaError Doc
seaOfReadAnyFact states config = do
  let tss = fmap (lookupTombstones config) states
  readStates_sea <- zipWithM seaOfReadFact states tss
  pure $ vsep
    [ vsep readStates_sea
    , ""
    , "#line 1 \"read any fact\""
    , "static psv_error_t psv_read_fact"
    , "  ( ifleet_t     *fleet"
    , "  , const char   *attrib"
    , "  , const size_t  attrib_size"
    , "  , const char   *value"
    , "  , const size_t  value_size"
    , "  , idate_t       date )"
    , "{"
    , "    /* don't read values after the snapshot date */"
    , "    if (date > fleet->snapshot_date)"
    , "        return 0;"
    , ""
    , "    const size_t attrib0_size = attrib_size + 1;"
    , indent 4 (vsep (fmap seaOfReadNamedFact states))
    , ""
    , "    return 0;"
    , "}"
    ]

seaOfReadNamedFact :: SeaProgramState -> Doc
seaOfReadNamedFact state
 = vsep
 [ ""
 , "if (" <> seaOfStringEq (getAttribute (stateAttribute state)) "attrib" (Just "attrib_size") <> ") {"
 , "    return " <> pretty (nameOfReadFact state)
                 <> " (&fleet->" <> pretty (nameOfProgram state) <> ", value, value_size, date);"
 , "}"
 ]

------------------------------------------------------------------------

nameOfReadFact :: SeaProgramState -> Text
nameOfReadFact state = T.pack ("psv_read_fact_" <> show (stateName state))

seaOfReadFact :: SeaProgramState -> Set Text -> Either SeaError Doc
seaOfReadFact state tombstones = do
  input     <- checkInputType state
  readInput <- seaOfReadInput input
  pure $ vsep
    [ "#line 1 \"read fact" <+> seaOfStateInfo state <> "\""
    , "static istring_t INLINE"
        <+> pretty (nameOfReadFact  state) <+> "("
         <> pretty (nameOfStateType state) <+> "*program,"
        <+> "const char *value_ptr, const size_t value_size, idate_t date)"
    , "{"
    , "    psv_error_t error;"
    , ""
    , "    imempool_t *mempool   = program->mempool;"
    , "    iint_t      new_count = program->new_count;"
    , ""
    , "    char  *p  = (char *) value_ptr;"
    , "    char  *pe = (char *) value_ptr + value_size;"
    , ""
    , "    ibool_t " <> pretty (inputSumBool input) <> ";"
    , indent 4 . vsep . fmap seaOfDefineInput $ inputVars input
    , ""
    , "    " <> align (seaOfReadTombstone input (Set.toList tombstones)) <> "{"
    , "        " <> pretty (inputSumBool input) <> " = itrue;"
    , ""
    , indent 8 readInput
    , "    }"
    , ""
    , "    program->" <> pretty (inputSumBool  input) <> "[new_count] = " <> pretty (inputSumBool input) <> ";"
    , "    program->" <> pretty (inputSumError input) <> "[new_count] = ierror_tombstone;"
    , indent 4 . vsep . fmap seaOfAssignInput $ inputVars input
    , "    program->" <> pretty (inputDate     input) <> "[new_count] = date;"
    , ""
    , "    new_count++;"
    , ""
    , "    if (new_count == psv_max_row_count) {"
    , "        " <> pretty (nameOfProgram state) <> " (program);"
    , "        new_count = 0;"
    , "    } else if (new_count > psv_max_row_count) {"
    , "        return \"" <> pretty (nameOfReadFact state) <> ": new_count > max_count\";"
    , "    }"
    , ""
    , "    program->new_count = new_count;"
    , ""
    , "    return 0; /* no error */"
    , "}"
    , ""
    ]

seaOfAssignInput :: (Text, ValType) -> Doc
seaOfAssignInput (n, _)
 = "program->" <> pretty n <> "[new_count] = " <> pretty n <> ";"

seaOfDefineInput :: (Text, ValType) -> Doc
seaOfDefineInput (n, t)
 = seaOfValType t <+> pretty n <> initType t

initType :: ValType -> Doc
initType vt = " = " <> seaOfXValue (defaultOfType vt) vt <> ";"

------------------------------------------------------------------------

seaOfReadTombstone :: CheckedInput -> [Text] -> Doc
seaOfReadTombstone input = \case
  []     -> Pretty.empty
  (t:ts) -> "if (" <> seaOfStringEq t "value_ptr" (Just "value_size") <> ") {" <> line
         <> "    " <> pretty (inputSumBool input) <> " = ifalse;" <> line
         <> "} else " <> seaOfReadTombstone input ts

------------------------------------------------------------------------

data CheckedInput = CheckedInput {
    inputSumBool  :: Text
  , inputSumError :: Text
  , inputDate     :: Text
  , inputType     :: ValType
  , inputVars     :: [(Text, ValType)]
  } deriving (Eq, Ord, Show)

checkInputType :: SeaProgramState -> Either SeaError CheckedInput
checkInputType state
 = case stateInputType state of
     PairT (SumT ErrorT t) DateTimeT
      | (sumBool,  BoolT)  : xs0 <- stateInputVars state
      , (sumError, ErrorT) : xs1 <- xs0
      , Just vars                <- init xs1
      , Just (date, DateTimeT)   <- last xs1
      -> Right CheckedInput {
             inputSumBool  = newPrefix <> sumBool
           , inputSumError = newPrefix <> sumError
           , inputDate     = newPrefix <> date
           , inputType     = t
           , inputVars     = fmap (first (newPrefix <>)) vars
           }

     t
      -> Left (SeaUnsupportedInputType t)

seaOfReadInput :: CheckedInput -> Either SeaError Doc
seaOfReadInput input
 = case (inputVars input, inputType input) of
    ([(nx, BoolT)], BoolT)
     -> pure $ vsep
        [ "error = psv_read_bool (&p, pe, &" <> pretty nx <> ");"
        , "if (error) return error;"
        ]

    ([(nx, DoubleT)], DoubleT)
     -> pure $ vsep
        [ "error = psv_read_double (&p, pe, &" <> pretty nx <> ");"
        , "if (error) return error;"
        ]

    ([(nx, IntT)], IntT)
     -> pure $ vsep
        [ "error = psv_read_int (&p, pe, &" <> pretty nx <> ");"
        , "if (error) return error;"
        ]

    ([(nx, DateTimeT)], DateTimeT)
     -> pure $ vsep
        [ "error = psv_read_date (value_ptr, value_size, &" <> pretty nx <> ");"
        , "if (error) return error;"
        ]

    ([(nx, StringT)], StringT)
     -> pure $ vsep
        [ "error = psv_read_string (mempool, &p, pe, &" <> pretty nx <> ");"
        , "if (error) return error;"
        ]

    (_, t@(ArrayT _))
     -> seaOfReadJsonValue assignVar t (inputVars input)

    (_, t@(StructT _))
     -> seaOfReadJsonValue assignVar t (inputVars input)

    (_, t)
     -> Left (SeaUnsupportedInputType t)

------------------------------------------------------------------------

-- Describes how to assign to a C struct member, this changes for arrays
type Assignment = Doc -> ValType -> Doc -> Doc

assignVar :: Assignment
assignVar n _ x = pretty n <+> "=" <+> x <> ";"

assignArray :: Assignment
assignArray n t x = n <+> "=" <+> seaOfArrayPut n "ix" x t <> ";"

seaOfArrayPut :: Doc -> Doc -> Doc -> ValType -> Doc
seaOfArrayPut arr ix val typ
 = seaOfPrimDocApps (seaOfXPrim (PrimUpdate (PrimUpdateArrayPut typ)))
                    [ arr, ix, val ]

seaOfArrayIndex :: Doc -> Doc -> ValType -> Doc
seaOfArrayIndex arr ix typ
 = seaOfPrimDocApps (seaOfXPrim (PrimUnsafe (PrimUnsafeArrayIndex typ)))
                    [ arr, ix ]

------------------------------------------------------------------------

seaOfReadJsonValue :: Assignment -> ValType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonValue assign vtype vars
 = let readValueArg arg n vt suf = vsep
         [ seaOfValType vtype <+> "value;"
         , "error = psv_read_" <> suf <> " (" <> arg <> "&p, pe, &value);"
         , "if (error) return error;"
         , assign (pretty n) vt "value"
         ]

       readValue     = readValueArg ""
       readValuePool = readValueArg "mempool, "

   in case (vars, vtype) of
       ([(nb, BoolT), nx], OptionT t) -> do
         val_sea <- seaOfReadJsonValue assign t [nx]
         pure $ vsep
           [ "ibool_t is_null;"
           , "error = psv_try_read_json_null (&p, pe, &is_null);"
           , "if (error) return error;"
           , ""
           , "if (is_null) {"
           , indent 4 (assign (pretty nb) BoolT "ifalse")
           , "} else {"
           , indent 4 (assign (pretty nb) BoolT "itrue")
           , ""
           , indent 4 val_sea
           , "}"
           ]

       ([(nx, BoolT)], BoolT)
        -> pure (readValue nx BoolT "json_bool")

       ([(nx, IntT)], IntT)
        -> pure (readValue nx IntT "int")

       ([(nx, DoubleT)], DoubleT)
        -> pure (readValue nx DoubleT "double")

       ([(nx, DateTimeT)], DateTimeT)
        -> pure (readValue nx DateTimeT "json_date")

       ([(nx, StringT)], StringT)
        -> pure (readValuePool nx StringT "json_string")

       (ns, StructT t)
        -> seaOfReadJsonObject assign t ns

       (ns, ArrayT t)
        -> seaOfReadJsonList t ns

       _
        -> Left (SeaInputTypeMismatch vtype vars)

------------------------------------------------------------------------

seaOfReadJsonList :: ValType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonList vtype avars = do
  vars      <- traverse unArray avars
  value_sea <- seaOfReadJsonValue assignArray vtype vars
  pure $ vsep
    [ "if (*p++ != '[')"
    , "    return psv_alloc_error (\"missing '['\",  p, pe - p);"
    , ""
    , "char term = *p;"
    , ""
    , "for (iint_t ix = 0; term != ']'; ix++) {"
    , indent 4 value_sea
    , "    "
    , "    term = *p++;"
    , "    if (term != ',' && term != ']')"
    , "        return psv_alloc_error (\"terminator ',' or ']' not found\", p, pe - p);"
    , "}"
    ]

unArray :: (Text, ValType) -> Either SeaError (Text, ValType)
unArray (n, ArrayT t) = Right (n, t)
unArray (n, t)        = Left (SeaInputTypeMismatch t [(n, t)])

------------------------------------------------------------------------

seaOfReadJsonObject :: Assignment -> StructType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonObject assign st@(StructType fs) vars
 = case vars of
    [(nx, UnitT)] | Map.null fs -> seaOfReadJsonUnit   assign nx
    _                           -> seaOfReadJsonStruct assign st vars

seaOfReadJsonUnit :: Assignment -> Text -> Either SeaError Doc
seaOfReadJsonUnit assign name = do
  pure $ vsep
    [ "if (*p++ != '{')"
    , "    return psv_alloc_error (\"missing {\",  p, pe - p);"
    , ""
    , "if (*p++ != '}')"
    , "    return psv_alloc_error (\"missing }\",  p, pe - p);"
    , ""
    , assign (pretty name) UnitT "iunit"
    ]

seaOfReadJsonStruct :: Assignment -> StructType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonStruct assign st@(StructType fields) vars = do
  let mismatch = SeaStructFieldsMismatch st vars
  mappings     <- maybe (Left mismatch) Right (mappingOfFields (Map.toList fields) vars)
  mappings_sea <- traverse (seaOfFieldMapping assign) mappings
  pure $ vsep
    [ "if (*p++ != '{')"
    , "    return psv_alloc_error (\"missing {\",  p, pe - p);"
    , ""
    , "for (;;) {"
    , "    if (*p++ != '\"')"
    , "        return psv_alloc_error (\"missing \\\"\", p, pe - p);"
    , ""
    , indent 4 (vsep mappings_sea)
    , "    return psv_alloc_error (\"invalid field start\", p, pe - p);"
    , "}"
    ]

seaOfFieldMapping :: Assignment -> FieldMapping -> Either SeaError Doc
seaOfFieldMapping assign (FieldMapping fname ftype vars) = do
  let needle = fname <> "\""
  field_sea <- seaOfReadJsonField assign ftype vars
  pure $ vsep
    [ "/* " <> pretty fname <> " */"
    , "if (" <> seaOfStringEq needle "p" Nothing <> ") {"
    , "    p += " <> int (sizeOfString needle) <> ";"
    , ""
    , indent 4 field_sea
    , ""
    , "    continue;"
    , "}"
    , ""
    ]

seaOfReadJsonField :: Assignment -> ValType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonField assign ftype vars = do
  value_sea <- seaOfReadJsonValue assign ftype vars
  pure $ vsep
    [ "if (*p++ != ':')"
    , "    return psv_alloc_error (\"missing ':'\",  p, pe - p);"
    , ""
    , value_sea
    , ""
    , "char term = *p++;"
    , "if (term != ',' && term != '}')"
    , "    return psv_alloc_error (\"terminator ',' or '}' not found\", p, pe - p);"
    , ""
    , "if (term == '}')"
    , "    break;"
    ]

------------------------------------------------------------------------

data FieldMapping = FieldMapping {
    _fieldName :: Text
  , _fieldType :: ValType
  , _fieldVars :: [(Text, ValType)]
  } deriving (Eq, Ord, Show)

mappingOfFields :: [(StructField, ValType)] -> [(Text, ValType)] -> Maybe [FieldMapping]
mappingOfFields []     []  = pure []
mappingOfFields []     _   = Nothing
mappingOfFields (f:fs) vs0 = do
  (m,  vs1) <- mappingOfField  f  vs0
  ms        <- mappingOfFields fs vs1
  pure (m : ms)

mappingOfField :: (StructField, ValType) -> [(Text, ValType)] -> Maybe (FieldMapping, [(Text, ValType)])
mappingOfField (StructField fname, ftype) vars0 = do
  let go t (n, t')
       | t == t'   = Just (n, t)
       | otherwise = Nothing

  ns <- zipWithM go (meltType ftype) vars0

  let mapping = FieldMapping fname ftype ns
      vars1   = drop (length ns) vars0

  return (mapping, vars1)

------------------------------------------------------------------------

type BufSize = Doc
type BufLen  = Doc

cond :: Doc -> Doc -> Doc
cond n body
 = vsep ["if (" <> n <> ")"
        , "{"
        , indent 4 body
        , "}"]

seaOfWriteFleetOutput :: [SeaProgramState] -> Either SeaError Doc
seaOfWriteFleetOutput states = do
  write_sea <- traverse seaOfWriteProgramOutput states
  pure $ vsep
    [ "#line 1 \"write all outputs\""
    , "static void psv_write_outputs (int fd, const char *entity, ifleet_t *fleet)"
    , "{"
    , indent 4 (vsep write_sea)
    , "}"
    ]

seaOfWriteProgramOutput :: SeaProgramState -> Either SeaError Doc
seaOfWriteProgramOutput state = do
  let ps = "p" <> int (stateName state)

  let resumeables = fmap (\(n,_) -> ps <> "->" <> pretty (hasPrefix <> n) <+> "= ifalse;") (stateResumables state)
  outputs <- traverse (\(n,(t,ts)) -> seaOfWriteOutput ps n t ts 0) (stateOutputs state)

  pure $ vsep
    [ ""
    , "/* " <> seaOfAttributeDesc (stateAttribute state) <> " */"
    , pretty (nameOfStateType state) <+> "*" <> ps <+> "=" <+> "&fleet->" <> pretty (nameOfProgram state) <> ";"
    , pretty (nameOfProgram state) <+> "(" <> ps <> ");"
    , ps <> "->new_count = 0;"
    , vsep resumeables
    , ""
    , vsep outputs
    ]

seaOfWriteOutput :: Doc -> OutputName -> ValType -> [ValType] -> Int -> Either SeaError Doc
seaOfWriteOutput ps oname@(OutputName name) otype0 ts0 ixStart
  = let members = List.take (length ts0) (fmap (\ix -> ps <> "->" <> seaOfNameIx name ix) [ixStart..])
    in case otype0 of
         -- Top-level Sum is a special case, to avoid allocating and printing if
         -- the whole computation is an error (e.g. tombstone)
         SumT ErrorT otype1
          | (BoolT : ErrorT : ts1) <- ts0
          , (nb    : _      : _)   <- members
          -> do (body, bufs) <- seaOfOutput ps oname otype1 ts1 (ixStart+2) outbuf
                body'        <- go body bufs
                pure $ cond nb body'
         _
          -> do (str, bufs) <- seaOfOutput ps oname otype0 ts0 ixStart outbuf
                go str bufs

  where
    attrib      = seaOfEscaped name
    dprintf n   = "dprintf (fd, \"%s|" <> attrib <> "|%s\\n\"" <> ", entity, " <> n <> ");"
    free s      = "free (" <> s <> ");"
    calloc  n s = "char *" <> n <> " = calloc(1," <> s <> " );"
    decli   n   = "int   " <> n <> " = 0;"
    decldt      = "iint_t v_year, v_month, v_day, v_hour, v_minute, v_second;" :: Doc
    outbuf      = "output_buf_" <> pretty name
    plus x y    = x <+> "+" <+> y

    go str bufs
     = let sz = List.foldr plus "0" (fmap fst bufs)
       in  pure
            $ vsep
            $  [ if hasDateTime otype0 then decldt else mempty
               , calloc outbuf sz
               ]
            <> fmap decli (List.nubBy same $ fmap snd $ List.reverse bufs)
            <> [ str
               , dprintf outbuf
               , free outbuf
               ]

    same d1 d2 = show d1 == show d2

    hasDateTime DateTimeT   = True
    hasDateTime (ArrayT t)  = hasDateTime t
    hasDateTime (BufT _ t)  = hasDateTime t
    hasDateTime (OptionT t) = hasDateTime t
    hasDateTime (MapT k v)  = hasDateTime k || hasDateTime v
    hasDateTime (PairT a b) = hasDateTime a || hasDateTime b
    hasDateTime (SumT a b)  = hasDateTime a || hasDateTime b
    hasDateTime (StructT m) = any hasDateTime $ Map.elems $ getStructType m
    hasDateTime _           = False

seaOfOutput
  :: Doc -> OutputName -> ValType -> [ValType] -> Int
  -> Doc                                        -- buffer to print to
  -> Either SeaError (Doc, [(BufSize, BufLen)]) -- name, alloc size and len

seaOfOutput ps oname@(OutputName name) otype0 ts0 ixStart dstbuf
  = let members = List.take (length ts0) (fmap (\ix -> ps <> "->" <> seaOfNameIx name ix) [ixStart..])
    in case otype0 of
         SumT ErrorT otype1
          | (BoolT : ErrorT : ts1) <- ts0
          , (nb    : _      : _)   <- members
          -> do (doc, bs) <- seaOfOutput ps oname otype1 ts1 (ixStart+2) dstbuf
                pure (cond nb doc, bs)

         OptionT otype1
          | (BoolT : ts1) <- ts0
          , (nb    : _)   <- members
          -> do (doc, bs) <- seaOfOutput ps oname otype1 ts1 (ixStart+1) dstbuf
                pure (cond nb doc, bs)

         PairT _ _
          -> seaOfOutputPair ts0 members

         ArrayT (SumT ErrorT _)
          | [ArrayT BoolT , ArrayT ErrorT , ArrayT elemT] <- ts0
          , [boolA        , _             , elemA       ] <- members
          -> let prefix   = pretty name
                 counter  = prefix <> "_i"
                 len      = "len_" <> prefix -- lies
             in  do (body, bs) <- seaOfOutputBase' elemT (seaOfArrayIndex elemA counter elemT) len
                    let body'   = cond (seaOfArrayIndex boolA counter BoolT) body
                    seaOfOutputArray body' bs elemA prefix len

         _
          | [t]  <- ts0
          , [mx] <- members
          -> seaOfOutputBase t mx

         _ -> unsupported
  where
   mismatch    = Left (SeaOutputTypeMismatch oname otype0 ts0)
   unsupported = Left (SeaUnsupportedOutputType otype0)

   -- Output an array with pre-defined bodies
   seaOfOutputArray :: Doc -> [(BufSize, BufLen)] -> Doc -> Doc -> Doc
                    -> Either SeaError (Doc, [(BufSize, BufLen)])
   seaOfOutputArray body bs array prefix len
    = let counter = prefix <> "_i"
          limit   = prefix <> "_n"
          db      = dstbuf <+> "+" <+> len
          numElems= array <> "->count"
          b       = case bs of
                     ((s,_):_)
                        -- enough space for array elements, commas and backets
                        -> [("(" <> s <+> "*" <+> numElems <+> ") +" <+> numElems <+> "+ 1"
                            , len)]
                     _  -> mempty
      in  pure
           (vsep [ ch db "["
                 , inc len
                 , forstm counter limit numElems
                 , "{"
                 , indent 4 $ cond (counter <+> "> 0")  (vsep [ ch db ",", inc len ])
                 , indent 4 body
                 , "}"
                 , ch db "]"
                 , inc len
                 ]
           , b <> bs
           )

   -- Output (nested) pairs as array
   seaOfOutputPair :: [ValType] -> [Doc]
                   -> Either SeaError (Doc, [(BufSize, BufLen)])
   seaOfOutputPair ts ns
    = let len  = lenn $ mconcat ns
          db   = dstbuf <+> "+" <+> len
          go (i, sz, stms, bs) t
           | Right (doc, bb@((bufsz,buflen):_)) <- seaOfOutput ps oname t [t] (ixStart + i) db
           = pure
           ( i + 1
           , sz <+> "+" <+> bufsz
           , stms <> [ vsep [ doc
                            , incAssign len buflen
                            ]
                     ]
           , bb <> bs
           )
           | otherwise
           = mismatch
          com  []       = []
          com  (s:ss)   = com' s ss
          com' a []     = [a]
          com' a (s:ss) = vsep [a, ch db ",", inc len]
                        : com' s ss
      in  do (i, sz, stms, bs) <- foldM go (0, "2", mempty, mempty) ts
             let size           = sz <+> "+" <+> pretty i
                 stms'          = com stms
                 stms''         = vsep
                                  $  [ ch db  "["
                                     , inc len
                                     ]
                                  <> stms'
                                  <> [ ch db "]"
                                     , inc len
                                     ]
             pure (stms'', (size, len) : bs)

   -- Output single types
   seaOfOutputBase :: ValType -> Doc -> Either SeaError (Doc, [(BufSize, BufLen)])
   seaOfOutputBase t val
    = seaOfOutputBase' t val $ lenn val

   seaOfOutputBase' :: ValType -> Doc -> Doc -> Either SeaError (Doc, [(BufSize, BufLen)])
   seaOfOutputBase' t val len
    = let p s     = pure (vsep s, [(bufs, len)])
          dstbuf' = dstbuf <+> "+" <+> len
      in case t of
          BoolT
           -> p [ "if (" <> val <> ") {"
                , indent 4 $ snprintf len dstbuf' "%s" "\"true\""
                , "} else {"
                , indent 4 $ snprintf len dstbuf' "%s" "\"false\""
                , "}"
                ]
          IntT
           -> p [snprintf len dstbuf' "%lld" val]
          DoubleT
           -> p [snprintf len dstbuf' "%f" val]
          StringT
           -> p [snprintf len dstbuf' "%s" val]
          DateTimeT
           -> p [ "idate_to_gregorian (" <> val <> ", &v_year, &v_month, &v_day, &v_hour, &v_minute, &v_second);"
                , snprintf len dstbuf' dateFmt "v_year, v_month, v_day, v_hour, v_minute, v_second"
                ]

          _ -> mismatch


   dateFmt = "%lld-%02lld-%02lldT%02lld:%02lld:%02lld"
   bufs    = "psv_output_buf_size"
   lenn n  = "len_" <> mkName n
   mkName  = string . filter isAlphaNum . show

   -- for(size_t i = 0, i < n, i++)
   forstm i n m
    = "for(iint_t" <+> i <+> "= 0," <+> n <+> "=" <+> m <> ";" <+> i <+> "<" <+> n <> "; ++" <> i <> ")"

   -- *n = x;
   ch n x = "*(" <> n <> ") = '" <> x <> "';"

   -- snprintf (buf, psv_output_buf_size, "%fmt", n,);
   snprintf i buf fmt n = i <> " += snprintf (" <> buf <> ", psv_output_buf_size,\"" <> fmt <> "\", " <> n <> ");"

   incAssign n i = n <+> "+=" <+> i <> ";"
   inc n         = n <>  "++;"

------------------------------------------------------------------------

sizeOfString :: Text -> Int
sizeOfString = B.length . T.encodeUtf8

seaOfStringEq :: Text -> Doc -> Maybe Doc -> Doc
seaOfStringEq str ptr msize
 | Just size <- msize = align (vsep [szdoc size, cmpdoc])
 | otherwise          = align cmpdoc
 where
   nbytes = length bytes
   bytes  = B.unpack (T.encodeUtf8 str)

   szdoc size = size <+> "==" <+> int nbytes <+> "&&"
   cmpdoc     = seaOfBytesEq bytes ptr

seaOfBytesEq :: [Word8] -> Doc -> Doc
seaOfBytesEq bs ptr
 = vsep . punctuate " &&" . reverse $ seaOfBytesEq' bs 0 ptr []

seaOfBytesEq' :: [Word8] -> Int -> Doc -> [Doc] -> [Doc]
seaOfBytesEq' [] _   _   acc = acc
seaOfBytesEq' bs off ptr acc
 = seaOfBytesEq' remains (off + 8) ptr (doc : acc)
 where
   (bytes, remains) = splitAt 8 bs

   nbytes = length bytes

   nzeros = 8 - nbytes
   zeros  = List.replicate nzeros 0x00

   mask = text $ "0x" <> concatMap (printf "%02X") (zeros <> List.replicate nbytes 0xff)
   bits = text $ "0x" <> concatMap (printf "%02X") (zeros <> reverse bytes)

   doc = "(*(uint64_t *)(" <> ptr <+> "+" <+> int off <> ") &" <+> mask <> ") ==" <+> bits

lookupTombstones :: PsvConfig -> SeaProgramState -> Set Text
lookupTombstones config state =
  fromMaybe Set.empty (Map.lookup (stateAttribute state) (psvTombstones config))

last :: [a] -> Maybe a
last []     = Nothing
last (x:[]) = Just x
last (_:xs) = last xs

init :: [a] -> Maybe [a]
init []     = Nothing
init (_:[]) = Just []
init (x:xs) = (x:) <$> init xs
