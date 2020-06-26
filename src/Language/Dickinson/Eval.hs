{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

module Language.Dickinson.Eval ( EvalM
                               , EvalSt (..)
                               , addDecl
                               , loadDickinson
                               , evalDickinsonAsMain
                               , resolveExpressionM
                               , evalExpressionM
                               , evalExpressionAsTextM
                               , evalWithGen
                               , evalIO
                               , findDecl
                               , findMain
                               , lexerStateLens
                               , balanceMax
                               ) where

import           Control.Composition           (thread)
import           Control.Monad                 ((<=<))
import           Control.Monad.Except          (ExceptT, MonadError, runExceptT, throwError)
import qualified Control.Monad.Ext             as Ext
import           Control.Monad.IO.Class        (MonadIO (..))
import           Control.Monad.State.Lazy      (MonadState, StateT, evalStateT, get, gets, modify, put)
import           Data.Foldable                 (toList, traverse_)
import           Data.Functor                  (($>))
import qualified Data.IntMap                   as IM
import           Data.List.NonEmpty            (NonEmpty, (<|))
import qualified Data.List.NonEmpty            as NE
import qualified Data.Map                      as M
import qualified Data.Text                     as T
import           Data.Text.Prettyprint.Doc     (Doc, Pretty (..), vsep, (<+>))
import           Data.Text.Prettyprint.Doc.Ext
import           Data.Tuple.Ext
import           Language.Dickinson.Error
import           Language.Dickinson.Lexer
import           Language.Dickinson.Lib.Get
import           Language.Dickinson.Name
import           Language.Dickinson.Rename
import           Language.Dickinson.Type
import           Language.Dickinson.TypeCheck
import           Language.Dickinson.Unique
import           Lens.Micro                    (Lens', over, _1)
import           Lens.Micro.Mtl                (use, (.=))
import           System.Random                 (StdGen, newStdGen, randoms)

-- | The state during evaluation
data EvalSt a = EvalSt
    { probabilities :: [Double]
    -- map to expression
    , boundExpr     :: IM.IntMap (Expression a)
    , renameCtx     :: Renames
    -- TODO: map to uniques or an expression?
    -- TODO: module context for topLevel?
    , topLevel      :: M.Map T.Text Unique
    -- For imports & such.
    , lexerState    :: AlexUserState
    -- For error messages
    , tyEnv         :: TyEnv
    }


instance HasLexerState (EvalSt a) where
    lexerStateLens f s = fmap (\x -> s { lexerState = x }) (f (lexerState s))

prettyBound :: (Int, Expression a) -> Doc b
prettyBound (i, e) = pretty i <+> "←" <#*> pretty e

prettyTl :: (T.Text, Unique) -> Doc a
prettyTl (t, i) = pretty t <+> ":" <+> pretty i

instance Pretty (EvalSt a) where
    pretty (EvalSt _ b r t st _) =
        "bound expressions:" <#> vsep (prettyBound <$> IM.toList b)
            <#> pretty r
            <#> "top-level names:" <#> vsep (prettyTl <$> M.toList t)
            <#> prettyAlexState st

prettyAlexState :: AlexUserState -> Doc a
prettyAlexState (m, _, nEnv) =
        "max:" <+> pretty m
    <#> prettyDumpBinds nEnv

instance HasRenames (EvalSt a) where
    rename f s = fmap (\x -> s { renameCtx = x }) (f (renameCtx s))

instance HasTyEnv (EvalSt a) where
    tyEnvLens f s = fmap (\x -> s { tyEnv = x }) (f (tyEnv s))

probabilitiesLens :: Lens' (EvalSt a) [Double]
probabilitiesLens f s = fmap (\x -> s { probabilities = x }) (f (probabilities s))

boundExprLens :: Lens' (EvalSt a) (IM.IntMap (Expression a))
boundExprLens f s = fmap (\x -> s { boundExpr = x }) (f (boundExpr s))

topLevelLens :: Lens' (EvalSt a) (M.Map T.Text Unique)
topLevelLens f s = fmap (\x -> s { topLevel = x }) (f (topLevel s))

-- TODO: thread generator state instead?
type EvalM a = StateT (EvalSt a) (ExceptT (DickinsonError a) IO)

evalIO :: AlexUserState -> EvalM a x -> IO (Either (DickinsonError a) x)
evalIO rs me = (\g -> evalWithGen g rs me) =<< newStdGen

evalWithGen :: StdGen
            -> AlexUserState -- ^ Threaded through
            -> EvalM a x
            -> IO (Either (DickinsonError a) x)
evalWithGen g u me = runExceptT $ evalStateT me (EvalSt (randoms g) mempty (initRenames $ fst3 u) mempty u mempty)

nameMod :: Name a -> Expression a -> EvalSt a -> EvalSt a
nameMod (Name _ (Unique u) _) e = over boundExprLens (IM.insert u e)

bindName :: (MonadState (EvalSt a) m) => Name a -> Expression a -> m ()
bindName n e = modify (nameMod n e)

topLevelMod :: Name a -> EvalSt a -> EvalSt a
topLevelMod (Name n u _) = over topLevelLens (M.insert (T.intercalate "." $ toList n) u)

topLevelAdd :: (MonadState (EvalSt a) m) => Name a -> m ()
topLevelAdd n = modify (topLevelMod n)

lookupName :: (MonadState (EvalSt a) m, MonadError (DickinsonError a) m) => Name a -> m (Expression a)
lookupName n@(Name _ u l) = do
    (Unique u') <- replaceUnique u
    go =<< gets (IM.lookup u'.boundExpr)
    where go Nothing  = throwError (UnfoundName l n)
          go (Just x) = {-# SCC "renameClone" #-} renameExpressionM x

normalize :: (Foldable t, Functor t, Fractional a) => t a -> t a
normalize xs = {-# SCC "normalize" #-} (/tot) <$> xs
    where tot = sum xs

cdf :: (Num a) => NonEmpty a -> [a]
cdf = {-# SCC "cdf" #-} NE.drop 2 . NE.scanl (+) 0 . (0 <|)

pick :: (MonadState (EvalSt a) m) => NonEmpty (Double, Expression a) -> m (Expression a)
pick brs = {-# SCC "pick" #-} do
    threshold <- gets (head.probabilities)
    modify (over probabilitiesLens tail)
    let ds = cdf (normalize (fst <$> brs))
        es = toList (snd <$> brs)
    pure $ snd . head . dropWhile ((<= threshold) . fst) $ zip ds es

findDecl :: (MonadState (EvalSt a) m, MonadError (DickinsonError a) m) => T.Text -> m (Expression a)
findDecl t = do
    tops <- gets topLevel
    case M.lookup t tops of
        Just (Unique i) -> do { es <- gets boundExpr ; pure (es IM.! i) }
        Nothing         -> throwError (NoText t)

findMain :: (MonadState (EvalSt a) m, MonadError (DickinsonError a) m) => m (Expression a)
findMain = findDecl "main"

evalDickinsonAsMain :: (MonadError (DickinsonError a) m, MonadState (EvalSt a) m)
                    => [Declaration a]
                    -> m T.Text
evalDickinsonAsMain d =
    loadDickinson d *>
    (evalExpressionAsTextM =<< findMain)

loadDickinson :: (MonadError (DickinsonError a) m, MonadState (EvalSt a) m)
              => [Declaration a]
              -> m ()
loadDickinson = traverse_ addDecl

balanceMax :: (HasRenames s, HasLexerState s) => MonadState s m => m ()
balanceMax = do
    m0 <- use (rename.maxLens)
    m1 <- use (lexerStateLens._1)
    let m' = max m0 m1
    rename.maxLens .= m'
    lexerStateLens._1 .= m'

declToStMod :: Declaration a -> EvalSt a -> EvalSt a
declToStMod (Define _ n e) = topLevelMod n . nameMod n e

addDecl :: (MonadState (EvalSt a) m)
        => Declaration a
        -> m ()
addDecl (Define _ n e) = bindName n e *> topLevelAdd n

extrText :: (HasTyEnv s, MonadState s m, MonadError (DickinsonError a) m) => Expression a -> m T.Text
extrText (Literal _ t)  = pure t
extrText (StrChunk _ t) = pure t
extrText e              = do { ty <- typeOf e ; throwError $ TypeMismatch e TyText ty }

withSt :: (MonadState s m) => (s -> s) -> m b -> m b
withSt modSt act = do
    preSt <- get
    modify modSt
    act <* put preSt

bindPattern :: (MonadError (DickinsonError a) m, MonadState (EvalSt a) m) => Pattern a -> Expression a -> m (EvalSt a -> EvalSt a)
bindPattern (PatternVar _ n) e               = pure $ nameMod n e
bindPattern Wildcard{} _                     = pure id
bindPattern (PatternTuple _ ps) (Tuple _ es) = thread <$> Ext.zipWithM bindPattern ps es
bindPattern (PatternTuple l _) _             = throwError $ MalformedTuple l

evalExpressionM :: (MonadState (EvalSt a) m, MonadError (DickinsonError a) m) => Expression a -> m (Expression a)
evalExpressionM e@Literal{}    = pure e
evalExpressionM e@StrChunk{}   = pure e
evalExpressionM (Var _ n)      = evalExpressionM =<< lookupName n
evalExpressionM (Choice _ pes) = evalExpressionM =<< pick pes
evalExpressionM (Interp l es)  = concatOrFail l es
evalExpressionM (Concat l es)  = concatOrFail l es
evalExpressionM (Tuple l es)   = Tuple l <$> traverse evalExpressionM es
evalExpressionM (Let _ bs e) = do
    let stMod = thread $ fmap (uncurry nameMod) bs
    withSt stMod $
        evalExpressionM e
evalExpressionM (Apply _ e e') = do
    e'' <- evalExpressionM e
    case e'' of
        Lambda _ n _ e''' ->
            withSt (nameMod n e') $
                evalExpressionM e'''
        _ -> error "Ill-typed expression"
evalExpressionM e@Lambda{} = pure e
evalExpressionM (Match _ e p e') = do
    modSt <- bindPattern p =<< evalExpressionM e
    withSt modSt $
        evalExpressionM e'
evalExpressionM (Flatten _ e) = do
    e' <- resolveExpressionM e
    evalExpressionM ({-# SCC "mapChoice.setFrequency" #-} mapChoice setFrequency e')
evalExpressionM (Annot _ e _) = evalExpressionM e

mapChoice :: (NonEmpty (Double, Expression a) -> NonEmpty (Double, Expression a)) -> Expression a -> Expression a
mapChoice f (Choice l pes) = Choice l (f pes)
mapChoice _ e@Literal{}    = e
mapChoice _ e@StrChunk{}   = e

setFrequency :: NonEmpty (Double, Expression a) -> NonEmpty (Double, Expression a)
setFrequency = fmap (\(_, e) -> (fromIntegral $ {-# SCC "countNodes" #-} countNodes e, e))

countNodes :: Expression a -> Int
countNodes Literal{}      = 1
countNodes StrChunk{}     = 1
countNodes (Choice _ pes) = sum (fmap (countNodes . snd) pes)
countNodes (Interp _ es)  = product (fmap countNodes es)
countNodes (Concat _ es)  = product (fmap countNodes es)

concatOrFail :: (MonadState (EvalSt a) m, MonadError (DickinsonError a) m) => a -> [Expression a] -> m (Expression a)
concatOrFail l = fmap (Literal l . mconcat) . traverse evalExpressionAsTextM

evalExpressionAsTextM :: (MonadState (EvalSt a) m, MonadError (DickinsonError a) m) => Expression a -> m T.Text
evalExpressionAsTextM = extrText <=< evalExpressionM

-- | Resolve let bindings and such; no not perform choices or concatenations.
resolveExpressionM :: (MonadState (EvalSt a) m, MonadError (DickinsonError a) m) => Expression a -> m (Expression a)
resolveExpressionM e@Literal{}  = pure e
resolveExpressionM e@StrChunk{} = pure e
resolveExpressionM (Var _ n)    = resolveExpressionM =<< lookupName n
resolveExpressionM (Choice l pes) = do
    let ps = fst <$> pes
    es <- traverse resolveExpressionM (snd <$> pes)
    pure $ Choice l (NE.zip ps es)
resolveExpressionM (Interp l es) = Interp l <$> traverse resolveExpressionM es
resolveExpressionM (Concat l es) = Concat l <$> traverse resolveExpressionM es
resolveExpressionM (Tuple l es) = Tuple l <$> traverse resolveExpressionM es
resolveExpressionM (Let _ bs e) = do
    let stMod = thread $ fmap (uncurry nameMod) bs
    withSt stMod $
        resolveExpressionM e
resolveExpressionM (Apply _ e e') = do
    e'' <- resolveExpressionM e
    case e'' of
        Lambda _ n _ e''' ->
            withSt (nameMod n e') $
                resolveExpressionM e'''
        _ -> error "Ill-typed expression"
resolveExpressionM e@Lambda{} = pure e
resolveExpressionM (Match _ e p e') =
    (bindPattern p =<< resolveExpressionM e) *>
    resolveExpressionM e'
resolveExpressionM (Flatten l e) =
    Flatten l <$> resolveExpressionM e
resolveExpressionM (Annot _ e _) = resolveExpressionM e
