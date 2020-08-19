module Language.Dickinson.Pattern.Useless ( PatternM
                                          , runPatternM
                                          , isExhaustive
                                          , patternEnvDecls
                                          ) where

import           Control.Monad             (forM, forM_)
import           Control.Monad.State       (State, evalState, get)
import           Data.Foldable             (toList, traverse_)
import           Data.IntMap               (findWithDefault)
import qualified Data.IntMap               as IM
import qualified Data.IntSet               as IS
import           Data.List.Ext
import           Data.List.NonEmpty        (NonEmpty ((:|)))
import qualified Data.List.NonEmpty        as NE
import           Data.Maybe                (mapMaybe)
import           Language.Dickinson.Name
import           Language.Dickinson.Type
import           Language.Dickinson.Unique
import           Lens.Micro                (Lens')
import           Lens.Micro.Mtl            (modifying)

-- all constructors of a
data PatternEnv = PatternEnv { allCons :: IM.IntMap IS.IntSet -- ^ all constructors indexed by type
                             , types   :: IM.IntMap Int -- ^ all types indexed by constructor
                             }

allConsLens :: Lens' PatternEnv (IM.IntMap IS.IntSet)
allConsLens f s = fmap (\x -> s { allCons = x }) (f (allCons s))

typesLens :: Lens' PatternEnv (IM.IntMap Int)
typesLens f s = fmap (\x -> s { types = x }) (f (types s))

declAdd :: Declaration a -> PatternM ()
declAdd Define{}         = pure ()
declAdd (TyDecl _ (Name _ (Unique i) _) cs) = do
    forM_ cs $ \(Name _ (Unique j) _) ->
        modifying typesLens (IM.insert j i)
    let cons = IS.fromList $ toList (unUnique . unique <$> cs)
    modifying allConsLens (IM.insert i cons)

patternEnvDecls :: [Declaration a] -> PatternM ()
patternEnvDecls = traverse_ declAdd

type PatternM = State PatternEnv

runPatternM :: PatternM a -> a
runPatternM = flip evalState (PatternEnv mempty mempty)

isWildcard :: Pattern a -> Bool
isWildcard Wildcard{}   = True
isWildcard PatternVar{} = True
-- FIXME: or pattern containing wildcard? -> sketchy
isWildcard _            = False

isTuple :: Pattern a -> Bool
isTuple PatternTuple{} = True
isTuple _              = False

extrConsPattern :: [Pattern a] -> [Pattern a]
extrConsPattern = concat . mapMaybe g where
    g p@PatternCons{}  = Just [p]
    g (OrPattern _ ps) = Just $ extrConsPattern (toList ps)
    g _                = Nothing

extrCons :: [Pattern a] -> [Name a]
extrCons = fmap patCons . extrConsPattern

internalError :: a
internalError = error "Internal error in pattern-match coverage checker."

tyError :: a
tyError = error "Exhaustiveness checker does not work on ill-typed programs."

errTup :: a
errTup = error "Tuple must have at least two elements."

-- given a constructor name, get the IntSet of all constructors of that type
assocUniques :: Name a -> PatternM IS.IntSet
assocUniques (Name _ (Unique i) _) = do
    st <- get
    let ty = findWithDefault undefined i (types st)
    pure $ findWithDefault undefined ty (allCons st)

isExhaustive :: [Pattern a] -> PatternM Bool
isExhaustive ps = not <$> useful ps (Wildcard undefined)

isCompleteSet :: [Name a] -> PatternM Bool
isCompleteSet []       = pure False
isCompleteSet ns@(n:_) = do
    allU <- assocUniques n
    let ty = unUnique . unique <$> ns
    pure $ IS.null (allU IS.\\ IS.fromList ty)

isComplete :: [Pattern a] -> PatternM Bool
isComplete = {-# SCC "isComplete" #-} isCompleteSet . extrCons

-- do the first columns form a complete set?
fstComplete :: [Pattern a] -> PatternM Bool
fstComplete = pc . extrFst
    where pc ps | any isTuple ps = pure True
                | otherwise = isComplete ps

-- Split pattern tuples into constructors (of the first argument) and its
-- tails
extrSplit :: [Pattern a] -> [([Pattern a], Pattern a)]
extrSplit = mapMaybe g where
    g (PatternTuple _ (p :| [p'])) = Just (extrConsPattern [p], p')
    g (PatternTuple l (p :| ps))   = Just (extrConsPattern [p], PatternTuple l (NE.fromList ps))
    g _                            = Nothing

extrFst :: [Pattern a] -> [Pattern a]
extrFst = mapMaybe g where
    g (PatternTuple _ (p :| _)) = Just p
    g _                         = Nothing


-- Specialize a stack of patterns w.r.t. a constructor pattern
specializeConstructor :: Pattern a -- ^ Constructor
                      -> [Pattern a]
                      -> [Pattern a]
specializeConstructor p'@(PatternCons _ c) = {-# SCC "specializeConstructor" #-}concatMap unstitch
    where unstitch (PatternTuple _ (_ :| []))                   = errTup
          unstitch (PatternTuple _ ((PatternCons _ c') :| [p])) | c' == c = [p]
                                                                | otherwise = []
          unstitch (PatternTuple _ (OrPattern _ ps :| [p]))     | c `elem` extrCons (toList ps) = [p]
                                                                | otherwise = []
          unstitch (PatternTuple _ (Wildcard{} :| [p]))         = [p]
          unstitch (PatternTuple _ (PatternVar{} :| [p]))       = [p]
          unstitch (PatternTuple l ((PatternCons _ c') :| ps))  | c == c' = [PatternTuple l $ NE.fromList ps]
                                                                | otherwise = []
          unstitch (PatternTuple l (OrPattern _ ps :| ps'))     | c `elem` extrCons (toList ps) = [PatternTuple l $ NE.fromList ps']
                                                                | otherwise = []
          unstitch (PatternTuple l (Wildcard{} :| ps))          = [PatternTuple l $ NE.fromList ps]
          unstitch (PatternTuple l (PatternVar{} :| ps))        = [PatternTuple l $ NE.fromList ps]
          unstitch (OrPattern _ ps)                             = specializeConstructor p' $ toList ps
          unstitch _                                            = internalError
specializeConstructor _                    = internalError

-- "un-stitch" or patterns... specialized matrix
useful :: [Pattern a] -> Pattern a -> PatternM Bool
useful [] _                                           = pure True
useful ps (OrPattern _ ps')                           = anyA (useful ps) ps' -- all?
useful ps _                                           | any isWildcard ps = pure False -- check for wildcards so that stripRelevant only gets tuples
useful ps (PatternCons _ c)                           = pure $ c `notElem` extrCons ps -- already checked for wildcards
useful _ (PatternTuple  _ (_ :| []))                  = errTup -- TODO: loc
useful ps@(PatternCons{}:_) Wildcard{}                = not <$> isComplete ps
useful ps@(PatternCons{}:_) PatternVar{}              = not <$> isComplete ps
useful ps@(PatternTuple{}:_) Wildcard{}               = do
    comp <- fstComplete ps
    if comp
        then or <$> forM (extrSplit ps) -- FIXME: only works when constructor is a tag, not with tuples!
            -- p must be a constructor (i.e. not an or-pattern) so it may be fed to
            -- specializeConstructor (hence the weird nesting and the function
            -- extrSplit)
            (\(pcs, pt) -> or <$> forM pcs -- pt "pattern tail"
                (\pc -> useful (specializeConstructor pc ps) pt))
        else undefined
useful ps@(PatternTuple{}:_) PatternVar{}             = undefined
useful ps@(OrPattern{}:_) Wildcard{}                  = undefined
useful ps@(OrPattern{}:_) PatternVar{}                = undefined
useful ps (PatternTuple _ (Wildcard{} :| ps'))        = undefined
useful ps (PatternTuple _ (PatternVar{} :| ps'))      = undefined
useful ps (PatternTuple _ ((PatternCons _ c) :| [p])) = useful (mapMaybe (stripRelevant c) ps) p
useful ps (PatternTuple l ((PatternCons _ c) :| ps')) = useful (mapMaybe (stripRelevant c) ps) (PatternTuple l $ NE.fromList ps')
useful ps (PatternTuple l (OrPattern _ ps' :| ps''))    = anyA (useful ps) [PatternTuple l (p :| ps'') | p <- toList ps']
useful ps (PatternTuple _ (PatternTuple _ p :| ps'))  = undefined

-- strip a pattern (presumed to be a constructor or or-pattern) to relevant parts
stripRelevant :: Name a -> Pattern a -> Maybe (Pattern a)
stripRelevant _ (PatternTuple _ (_ :| []))                   = errTup -- TODO: loc
stripRelevant c (PatternTuple _ ((PatternCons _ c') :| [p])) | c' == c = Just p
                                                             | otherwise = Nothing
stripRelevant _ (PatternTuple _ (PatternVar{} :| [p]))       = Just p
stripRelevant _ (PatternTuple _ (Wildcard{} :| [p]))         = Just p
stripRelevant c (PatternTuple _ ((OrPattern _ ps) :| [p]))   | c `elem` extrCons (toList ps) = Just p
                                                             | otherwise = Nothing
stripRelevant c (PatternTuple l ((PatternCons _ c') :| ps))  | c' == c = Just $ PatternTuple l (NE.fromList ps)
                                                             | otherwise = Nothing
stripRelevant c (PatternTuple l ((OrPattern _ ps) :| ps'))   | c `elem` extrCons (toList ps) = Just $ PatternTuple l (NE.fromList ps')
                                                             | otherwise = Nothing
stripRelevant _ (PatternTuple l (PatternVar{} :| ps))        = Just $ PatternTuple l (NE.fromList ps)
stripRelevant _ (PatternTuple l (Wildcard{} :| ps))          = Just $ PatternTuple l (NE.fromList ps)
stripRelevant _ OrPattern{}                                  = undefined -- re-stitch it basically?
stripRelevant _ _                                            = tyError -- if we call stripRelevant on a non-tuple, that means a constructor was "above" a tuple, which is
                                                                       -- ill-typed anyway. Also, we've already checked for wildcards/vars in useful ^
