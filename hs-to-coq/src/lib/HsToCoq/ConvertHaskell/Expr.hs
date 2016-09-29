{-# LANGUAGE LambdaCase, RecordWildCards,
             OverloadedLists, OverloadedStrings,
             FlexibleContexts #-}

module HsToCoq.ConvertHaskell.Expr (
  -- * Expressions
  convertExpr, convertLExpr,
  -- * Bindings
  convertLocalBinds,
  -- ** Generic
  convertTypedBindings, convertTypedBinding,
  -- * Functions, matches, and guards
  -- ** Functions
  convertFunction,
  -- ** Matches
  convertMatchGroup, convertMatch,
  -- ** Guards
  ConvertedGuard(..), convertGuard, guardTerm,
  convertLGRHSList, convertGRHSs, convertGRHS, convertGuards
  ) where

import Data.Bifunctor
import Data.Foldable
import Data.Traversable
import Data.Maybe
import Data.List.NonEmpty (NonEmpty(..), nonEmpty)
import qualified Data.List.NonEmpty as NEL
import qualified Data.Text as T

import Control.Monad.Except
import Control.Monad.Writer

import           Data.Map.Strict (Map)
import qualified Data.Set        as S
import qualified Data.Map.Strict as M

import GHC hiding (Name)
import Bag
import BasicTypes
import HsToCoq.Util.GHC.FastString
import RdrName
import HsToCoq.Util.GHC.Exception

import HsToCoq.Util.Functor
import HsToCoq.Util.GHC
import HsToCoq.Util.GHC.HsExpr
import HsToCoq.Coq.Gallina as Coq
import HsToCoq.Coq.Gallina.Util
import HsToCoq.Coq.FreeVars

import HsToCoq.ConvertHaskell.Monad
import HsToCoq.ConvertHaskell.InfixNames
import HsToCoq.ConvertHaskell.Variables
import HsToCoq.ConvertHaskell.Definitions
import HsToCoq.ConvertHaskell.Literals
import HsToCoq.ConvertHaskell.Type
import HsToCoq.ConvertHaskell.Pattern
import HsToCoq.ConvertHaskell.Sigs

--------------------------------------------------------------------------------

convertExpr :: ConversionMonad m => HsExpr RdrName -> m Term
convertExpr (HsVar x) =
  Var . toPrefix <$> var ExprNS x

convertExpr (HsIPVar _) =
  convUnsupported "implicit parameters"

-- FIXME actually handle overloading
convertExpr (HsOverLit OverLit{..}) =
  case ol_val of
    HsIntegral   _src int -> Num <$> convertInteger "integer literals" int
    HsFractional _        -> convUnsupported "fractional literals"
    HsIsString   _src str -> pure . String $ fsToText str

convertExpr (HsLit lit) =
  case lit of
    HsChar       _ c       -> pure $ InScope (String $ T.singleton c) "char"
    HsCharPrim   _ _       -> convUnsupported "`Char#' literals"
    HsString     _ fs      -> pure . String $ fsToText fs
    HsStringPrim _ _       -> convUnsupported "`Addr#' literals"
    HsInt        _ _       -> convUnsupported "`Int' literals"
    HsIntPrim    _ _       -> convUnsupported "`Int#' literals"
    HsWordPrim   _ _       -> convUnsupported "`Word#' literals"
    HsInt64Prim  _ _       -> convUnsupported "`Int64#' literals"
    HsWord64Prim _ _       -> convUnsupported "`Word64#' literals"
    HsInteger    _ int _ty -> Num <$> convertInteger "`Integer' literals" int
    HsRat        _ _       -> convUnsupported "`Rational' literals"
    HsFloatPrim  _         -> convUnsupported "`Float#' literals"
    HsDoublePrim _         -> convUnsupported "`Double#' literals"

convertExpr (HsLam mg) =
  uncurry Fun <$> convertFunction mg

convertExpr (HsLamCase PlaceHolder mg) =
  uncurry Fun <$> convertFunction mg

convertExpr (HsApp e1 e2) =
  App1 <$> convertLExpr e1 <*> convertLExpr e2

convertExpr (OpApp el eop PlaceHolder er) =
  case eop of
    L _ (HsVar hsOp) -> do
      op <- var ExprNS hsOp
      l  <- convertLExpr el
      r  <- convertLExpr er
      pure $ if identIsOperator op
             then Infix l op r
             else App2 (Var op) l r
    _ ->
      convUnsupported "non-variable infix operators"

convertExpr (NegApp _ _) =
  convUnsupported "negation"

convertExpr (HsPar e) =
  Parens <$> convertLExpr e

convertExpr (SectionL l opE) =
  convert_section (Just l) opE Nothing

convertExpr (SectionR opE r) =
  convert_section Nothing opE (Just r)

convertExpr (ExplicitTuple exprs boxity) =
  case boxity of
    Boxed -> do
      -- TODO A tuple constructor in the Gallina grammar?
      (tuple, args) <- runWriterT
                    .  fmap (foldl1 . App2 $ Var "pair")
                    .  for exprs $ unLoc <&> \case
                         Present e           -> lift $ convertLExpr e
                         Missing PlaceHolder -> do arg <- lift $ gensym "arg"
                                                   Var arg <$ tell [arg]
      pure $ maybe id Fun (nonEmpty $ map (Inferred Coq.Explicit . Ident) args) tuple
    Unboxed -> convUnsupported "unboxed tuples"

convertExpr (HsCase e mg) =
  Coq.Match <$> (fmap pure $ MatchItem <$> convertLExpr e <*> pure Nothing <*> pure Nothing)
            <*> pure Nothing
            <*> convertMatchGroup mg

convertExpr (HsIf overloaded c t f) =
  if maybe True isNoSyntaxExpr overloaded
  then If <$> convertLExpr c <*> pure Nothing <*> convertLExpr t <*> convertLExpr f
  else convUnsupported "overloaded if-then-else"

convertExpr (HsMultiIf PlaceHolder lgrhsList) =
  convertLGRHSList lgrhsList

convertExpr (HsLet binds body) =
  convertLocalBinds binds $ convertLExpr body

convertExpr (HsDo _ _ _) =
  convUnsupported "`do' expressions"

convertExpr (ExplicitList PlaceHolder overloaded exprs) =
  if maybe True isNoSyntaxExpr overloaded
  then foldr (Infix ?? "::") (Var "nil") <$> traverse convertLExpr exprs
  else convUnsupported "overloaded lists"

convertExpr (ExplicitPArr _ _) =
  convUnsupported "explicit parallel arrays"

convertExpr (RecordCon _ _ _) =
  convUnsupported "record constructors"

convertExpr (RecordUpd _ _ _ _ _) =
  -- TODO: And record accessors!
  convUnsupported "record updates"

convertExpr (ExprWithTySig e ty PlaceHolder) =
  HasType <$> convertLExpr e <*> convertLType ty

convertExpr (ExprWithTySigOut _ _) =
  convUnsupported "`ExprWithTySigOut' constructor"

convertExpr (ArithSeq _ _ _) =
  convUnsupported "arithmetic sequences"

convertExpr (PArrSeq _ _) =
  convUnsupported "parallel array arithmetic sequences"

convertExpr (HsSCC _ _ e) =
  convertLExpr e

convertExpr (HsCoreAnn _ _ e) =
  convertLExpr e

convertExpr (HsBracket _) =
  convUnsupported "Template Haskell brackets"

convertExpr (HsRnBracketOut _ _) =
  convUnsupported "`HsRnBracketOut' constructor"

convertExpr (HsTcBracketOut _ _) =
  convUnsupported "`HsTcBracketOut' constructor"

convertExpr (HsSpliceE _ _) =
  convUnsupported "Template Haskell expression splices"

convertExpr (HsQuasiQuoteE _) =
  convUnsupported "expression quasiquoters"

convertExpr (HsProc _ _) =
  convUnsupported "`proc' expressions"

convertExpr (HsStatic _) =
  convUnsupported "static pointers"

convertExpr (HsArrApp _ _ _ _ _) =
  convUnsupported "arrow application command"

convertExpr (HsArrForm _ _ _) =
  convUnsupported "arrow command formation"

convertExpr (HsTick _ e) =
  convertLExpr e

convertExpr (HsBinTick _ _ e) =
  convertLExpr e

convertExpr (HsTickPragma _ _ e) =
  convertLExpr e

convertExpr EWildPat =
  convUnsupported "wildcard pattern in expression"

convertExpr (EAsPat _ _) =
  convUnsupported "as-pattern in expression"

convertExpr (EViewPat _ _) =
  convUnsupported "view-pattern in expression"

convertExpr (ELazyPat _) =
  convUnsupported "lazy pattern in expression"

convertExpr (HsType ty) =
  convertLType ty

convertExpr (HsWrap _ _) =
  convUnsupported "`HsWrap' constructor"

convertExpr (HsUnboundVar x) =
  Var <$> freeVar x

--------------------------------------------------------------------------------

-- Module-local
convert_section :: (ConversionMonad m) => Maybe (LHsExpr RdrName) -> LHsExpr RdrName -> Maybe (LHsExpr RdrName) -> m Term
convert_section  ml opE mr = do
  let hs  = HsVar . mkVarUnqual . fsLit . T.unpack
      coq = Inferred Coq.Explicit . Ident
  
  arg <- gensym "arg"
  let orArg = fromMaybe (noLoc $ hs arg)
  Fun [coq arg] <$> convertExpr (OpApp (orArg ml) opE PlaceHolder (orArg mr))

--------------------------------------------------------------------------------

convertLExpr :: ConversionMonad m => LHsExpr RdrName -> m Term
convertLExpr = convertExpr . unLoc

--------------------------------------------------------------------------------

convertFunction :: ConversionMonad m => MatchGroup RdrName (LHsExpr RdrName) -> m (Binders, Term)
convertFunction mg = do
  eqns <- convertMatchGroup mg
  args <- case eqns of
            Equation (MultPattern args :| _) _ : _ ->
              traverse (const $ gensym "arg") args
            _ ->
              convUnsupported "empty `MatchGroup' in function"
  let argBinders = (Inferred Coq.Explicit . Ident) <$> args
      match      = Coq.Match (args <&> \arg -> MatchItem (Var arg) Nothing Nothing) Nothing eqns
  pure (argBinders, match)

--------------------------------------------------------------------------------

convertMatchGroup :: ConversionMonad m => MatchGroup RdrName (LHsExpr RdrName) -> m [Equation]
convertMatchGroup (MG alts _ _ _) = traverse (convertMatch . unLoc) alts

convertMatch :: ConversionMonad m => Match RdrName (LHsExpr RdrName) -> m Equation
convertMatch GHC.Match{..} = do
  pats <- maybe (convUnsupported "no-pattern case arms") pure . nonEmpty
            =<< traverse convertLPat m_pats
  oty  <- traverse convertLType m_type
  rhs  <- convertGRHSs m_grhss
  pure . Equation [MultPattern pats] $ maybe id (flip HasType) oty rhs

--------------------------------------------------------------------------------

-- TODO: include "statement" in name?
data ConvertedGuard = OtherwiseGuard
                    | BoolGuard      Term
                    | PatternGuard   Pattern Term
                    deriving (Eq, Ord, Show, Read)

convertGuard :: ConversionMonad m => [GuardLStmt RdrName] -> m [ConvertedGuard]
convertGuard [] = pure []
convertGuard gs = collapseGuards <$> traverse toCond gs where
  toCond (L _ (BodyStmt e _bind _guard _PlaceHolder)) =
    isTrue e >>= \case
      True  -> pure OtherwiseGuard
      False -> BoolGuard <$> convertLExpr e
  toCond (L _ (LetStmt _)) =
    convUnsupported "`let' statements in guards"
  toCond (L _ (BindStmt pat exp _bind _fail)) =
    PatternGuard <$> convertLPat pat <*> convertLExpr exp
  toCond _ =
    convUnsupported "impossibly fancy guards"

  -- TODO: Add multi-pattern-guard case
  addGuard g [] =
    [g]
  addGuard (BoolGuard cond') (BoolGuard cond : gs) =
    BoolGuard (App2 (Var "andb") cond' cond) : gs
  addGuard g' (g:gs) =
    g':g:gs
  addGuard _ _ =
    error "GHC BUG WORKAROUND: `OverloadedLists` confuses the exhaustiveness checker"
  
  collapseGuards = foldr addGuard []
  
  isTrue (L _ (HsVar x))         = ((||) <$> (== "otherwise") <*> (== "True")) <$> ghcPpr x
  isTrue (L _ (HsTick _ e))      = isTrue e
  isTrue (L _ (HsBinTick _ _ e)) = isTrue e
  isTrue (L _ (HsPar e))         = isTrue e
  isTrue _                       = pure False

-- Returns a function waiting for the next guard
guardTerm :: ConversionMonad m => [ConvertedGuard] -> Term -> (Term -> m Term)
guardTerm gs guarded unguarded = go gs where
  go [] =
    pure guarded
  go (OtherwiseGuard : []) =
    pure guarded
  go (OtherwiseGuard : (_:_)) =
    convUnsupported "unused guards after an `otherwise' (or similar)"
  go (BoolGuard cond : gs) =
    If cond Nothing <$> go gs <*> pure unguarded
  go (PatternGuard pat exp : gs) = do
    guarded' <- go gs
    pure $ Coq.Match [MatchItem exp Nothing Nothing] Nothing
                     [ Equation [MultPattern [pat]] guarded'
                     , Equation [MultPattern [UnderscorePat]] unguarded ]
  go _ =
    error "GHC BUG WORKAROUND: `OverloadedLists` confuses the exhaustiveness checker"

--------------------------------------------------------------------------------

convertGuards :: ConversionMonad m => [([ConvertedGuard],Term)] -> m Term
convertGuards [] = convUnsupported "empty lists of guarded statements"
convertGuards gs = foldrM (uncurry guardTerm) MissingValue gs
-- TODO: We could support enhanced fallthrough if we detected more
-- `MissingValue` cases, e.g.
--
--     foo (Con1 x y) | rel x y = rhs1
--     foo other                = rhs2
--
-- Right now, this doesn't catch the fallthrough.  Oh well!

convertGRHS :: ConversionMonad m => GRHS RdrName (LHsExpr RdrName) -> m ([ConvertedGuard],Term)
convertGRHS (GRHS gs rhs) = (,) <$> convertGuard gs <*> convertLExpr rhs

convertLGRHSList :: ConversionMonad m => [LGRHS RdrName (LHsExpr RdrName)] -> m Term
convertLGRHSList = convertGuards <=< traverse (convertGRHS . unLoc)

convertGRHSs :: ConversionMonad m => GRHSs RdrName (LHsExpr RdrName) -> m Term
convertGRHSs GRHSs{..} = convertLocalBinds grhssLocalBinds $ convertLGRHSList grhssGRHSs

--------------------------------------------------------------------------------

convertTypedBinding :: ConversionMonad m => Maybe Term -> HsBind RdrName -> m ConvertedBinding
convertTypedBinding _convHsTy VarBind{}    = convUnsupported "[internal] `VarBind'"
convertTypedBinding _convHsTy AbsBinds{}   = convUnsupported "[internal?] `AbsBinds'"
convertTypedBinding _convHsTy PatSynBind{} = convUnsupported "pattern synonym bindings"
convertTypedBinding _convHsTy PatBind{..}  = -- TODO use `_convHsTy`?
  ConvertedPatternBinding <$> convertLPat pat_lhs <*> convertGRHSs pat_rhs
convertTypedBinding  convHsTy FunBind{..}  = do
  (name, opName) <- freeVar (unLoc fun_id) <&> \case
                      name | identIsVariable name -> (name,            Nothing)
                           | otherwise            -> (infixToCoq name, Just name)
  
  let (tvs, coqTy) =
        -- The @forall@ed arguments need to be brought into scope
        let peelForall (Forall tvs body) = first (NEL.toList tvs ++) $ peelForall body
            peelForall ty                = ([], ty)
        in maybe ([], Nothing) (second Just . peelForall) convHsTy
  
  defn <-
    if all (null . m_pats . unLoc) $ mg_alts fun_matches
    then case mg_alts fun_matches of
           [L _ (GHC.Match _ [] mty grhss)] ->
             maybe (pure id) (fmap (flip HasType) . convertLType) mty <*> convertGRHSs grhss
           _ ->
             convUnsupported "malformed multi-match variable definitions"
    else do
      (argBinders, match) <- convertFunction fun_matches
      pure $ let bodyVars = getFreeVars match
             in if name `S.member` bodyVars || maybe False (`S.member` bodyVars) opName
                then Fix . FixOne $ FixBody name argBinders Nothing Nothing match -- TODO recursion and binary operators
                else Fun argBinders match
  
  pure . ConvertedDefinitionBinding $ ConvertedDefinition name tvs coqTy defn opName

--------------------------------------------------------------------------------

-- TODO mutual recursion :-(
convertTypedBindings :: ConversionMonad m
                     => [HsBind RdrName] -> Map Ident Signature
                     -> (ConvertedBinding -> m a)
                     -> Maybe (HsBind RdrName -> GhcException -> m a)
                     -> m [a]
convertTypedBindings defns sigs build mhandler =
  let processed defn = maybe id (ghandle . ($ defn)) mhandler . (build =<<)
  in for defns $ \defn -> do
       ty <- case defn of
               FunBind{fun_id = L _ hsName} ->
                 fmap sigType . (`M.lookup` sigs) <$> var ExprNS hsName
               _ ->
                 pure Nothing
       processed defn $ convertTypedBinding ty defn

--------------------------------------------------------------------------------

convertLocalBinds :: ConversionMonad m => HsLocalBinds RdrName -> m Term -> m Term
convertLocalBinds (HsValBinds (ValBindsIn binds lsigs)) body = localizeConversionState $ do
  sigs     <- convertLSigs lsigs
  convDefs <- convertTypedBindings (map unLoc . bagToList $ binds) sigs pure Nothing
  sequence_ $ mapMaybe (withConvertedBinding (withConvertedDefinitionOp $ rename ExprNS)
                                             (\_ _ -> Nothing))
                       convDefs
  let matchLet pat term body = Coq.Match [MatchItem term Nothing Nothing] Nothing
                                         [Equation [MultPattern [pat]] body]
  (foldr (withConvertedBinding (withConvertedDefinitionDef Let) matchLet) ?? convDefs) <$> body
convertLocalBinds (HsValBinds (ValBindsOut _ _)) _ =
  convUnsupported "post-renaming `ValBindsOut' bindings"
convertLocalBinds (HsIPBinds _) _ =
  convUnsupported "local implicit parameter bindings"
convertLocalBinds EmptyLocalBinds body =
  body
