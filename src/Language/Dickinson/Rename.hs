module Language.Dickinson.Rename ( renameDickinson
                                 , renameExpressionM
                                 , initRenames
                                 , RenameM
                                 , Renames (..)
                                 , HasRenames (..)
                                 ) where

import           Control.Composition       (thread)
import           Control.Monad.Ext         (zipWithM)
import           Control.Monad.State       (MonadState, State, runState)
import           Data.Bifunctor            (second)
import qualified Data.IntMap               as IM
import qualified Data.List.NonEmpty        as NE
import           Data.Semigroup            (Semigroup (..))
import           Language.Dickinson.Name
import           Language.Dickinson.Type
import           Language.Dickinson.Unique
import           Lens.Micro                (Lens')
import           Lens.Micro.Mtl            (modifying, use, (%=), (.=))

data Renames = Renames { max_ :: Int, bound :: IM.IntMap Int }

boundLens :: Lens' Renames (IM.IntMap Int)
boundLens f s = fmap (\x -> s { bound = x }) (f (bound s))

maxLens :: Lens' Renames Int
maxLens f s = fmap (\x -> s { max_ = x }) (f (max_ s))

class HasRenames a where
    rename :: Lens' a Renames

instance HasRenames Renames where
    rename = id

instance Semigroup Renames where
    (<>) (Renames m1 b1) (Renames m2 b2) = Renames (max m1 m2) (b1 <> b2)

instance Monoid Renames where
    mempty = Renames 0 mempty
    mappend = (<>)

type RenameM a = State Renames

initRenames :: UniqueCtx -> Renames
initRenames m = Renames m mempty

runRenameM :: UniqueCtx -> RenameM a x -> (x, UniqueCtx)
runRenameM m x = second max_ (runState x (initRenames m))

-- Make sure you don't have cycles in the renames map!
replaceVar :: (MonadState s m, HasRenames s) => Name a -> m (Name a)
replaceVar pre@(Name n (Unique i) l) = {-# SCC "replaceVar" #-} do
    rSt <- use (rename.boundLens)
    case IM.lookup i rSt of
        Just j  -> replaceVar $ Name n (Unique j) l
        Nothing -> pure pre

renameDickinson :: Int -> Dickinson Name a -> (Dickinson Name a, Int)
renameDickinson m ds = runRenameM m $ traverse renameDeclarationM ds

renameDeclarationM :: (MonadState s m, HasRenames s) => Declaration Name a -> m (Declaration Name a)
renameDeclarationM i@(Import _ n) = do
    (_, modR) <- withName n
    modifying rename modR
    pure i
renameDeclarationM (Define p n e) = do
    (n', modR) <- withName n
    modifying rename modR
    Define p n' <$> renameExpressionM e

withRenames :: (HasRenames s, MonadState s m) => (Renames -> Renames) -> m a -> m a
withRenames modSt act = do
    preSt <- use rename
    rename %= modSt
    -- idk
    postMax <- use (rename.maxLens)
    act <* (rename .= setMax (postMax + 1) preSt)

-- TODO: slow?
withName :: (HasRenames s, MonadState s m) => Name a -> m (Name a, Renames -> Renames)
withName (Name t (Unique i) l) = do
    m <- use (rename.maxLens)
    let newUniq = m+1
    rename.maxLens .= newUniq
    pure (Name t (Unique newUniq) l, mapBound (IM.insert i (m+1)))

mapBound :: (IM.IntMap Int -> IM.IntMap Int) -> Renames -> Renames
mapBound f (Renames m b) = Renames m (f b)

setMax :: Int -> Renames -> Renames
setMax i (Renames _ b) = Renames i b

renameExpressionM :: (MonadState s m, HasRenames s) => Expression Name a -> m (Expression Name a)
renameExpressionM e@Literal{} = pure e
renameExpressionM e@StrChunk{} = pure e
renameExpressionM (Var p n)   = Var p <$> replaceVar n
renameExpressionM (Choice p branches) = Choice p <$> branches'
    where branches' =
            let ds = fst <$> branches
                in let es = fmap snd branches
                    in NE.zip ds <$> traverse renameExpressionM es
renameExpressionM (Interp p es) = Interp p <$> traverse renameExpressionM es
renameExpressionM (Apply e e') = Apply <$> renameExpressionM e <*> renameExpressionM e'
renameExpressionM (Lambda p n e) = do
    (n', modR) <- withName n
    Lambda p n' <$> withRenames modR (renameExpressionM e)
renameExpressionM (Let p bs e) = do
    newBs <- traverse withName (fst <$> bs)
    let localRenames = snd <$> newBs
        newBinds = thread localRenames
        newNames = fst <$> newBs
        preNewBound = snd <$> bs
    newBound <-
        zipWithM (\r e' -> withRenames r (renameExpressionM e')) localRenames preNewBound
    withRenames newBinds $
        Let p (NE.zip newNames newBound) <$> renameExpressionM e
