{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
module BarPlot
    ( BarPlotType(..)
    , PlotConfig(..)
    , BarPlot(..)
    , barPlot
    ) where

import Control.Monad (forM, forM_)
import Control.Monad.Catch (handle)
import Data.Bifunctor (bimap, second)
import Data.Conduit (ConduitT, (.|))
import qualified Data.Conduit.Combinators as C
import Data.IntMap (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.List (intersperse)
import Data.Maybe (catMaybes)
import Data.Monoid (Any(..))
import Data.Set (Set)
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Vector (Vector)
import qualified Data.Vector as V
import qualified Data.Vector.Generic as Generic
import System.IO (Handle, hPutStr, stdout)

import Core
import RuntimeData (getBarPlotScript)
import Query (streamQuery)
import Schema
import Sql (Region, (==.))
import qualified Sql
import Utils.ImplTiming (ImplTiming(..))
import Utils.Pair (Pair(..), mergePair, toPair)
import Utils.Process (withStdin)
import VariantQuery (VariantInfo(..), VariantInfoConfig(..), variantInfoQuery)

import GlobalPlotOptions
import LevelQuery (levelTimePlotQuery)
import TimeQuery (timePlotQuery)

data BarPlotType
    = Levels
    | Totals
    | VsOptimal

data PlotConfig = PlotConfig
    { axisName :: String
    , slideFormat :: Bool
    , printStdout :: Bool
    , normalise :: Bool
    }

data BarPlot
    = BarPlot
    { barPlotGlobalOpts :: GlobalPlotOptions
    , barPlotPlotConfig :: PlotConfig
    , barPlotType :: BarPlotType
    , barPlotGraphs :: Set Text
    , barPlotImplementations :: Set Text
    }

queryVariants :: Key Algorithm -> Set Text -> SqlM (Set (Key Variant))
queryVariants algoId graphs = do
    gids <- Sql.selectSource [] [] $
        C.filter (\i -> S.member (graphName (Sql.entityVal i)) graphs)
        .| C.map Sql.entityKey
        .| C.foldMap S.singleton

    variantConfigId <- Sql.selectKeysList
        [VariantConfigAlgorithmId ==. algoId, VariantConfigIsDefault ==. True]
        [] >>= \case
            [key] -> return key
            [] -> logThrowM . PatternFailed $
              "No default variant config for algorithm #" <> showSqlKey algoId
            _ -> logThrowM . PatternFailed . mconcat $
                [ "Multiple default variant configs for algorithm #"
                , showSqlKey algoId ]

    variants <- forM (S.toList gids) $ \gId ->
        Sql.getBy $ UniqVariant gId variantConfigId

    return . S.fromList . map Sql.entityKey . catMaybes $ variants

barPlot :: BarPlot -> SqlM ()
barPlot BarPlot{barPlotGlobalOpts = GlobalPlotOptions{..}, ..} = do
    variants <- queryVariants globalPlotAlgorithm barPlotGraphs

    let variantFilter VariantInfo{variantId} = S.member variantId variants

    case barPlotType of
        Levels -> forM_ variants $ \variantId -> do
            graphId <- variantGraphId <$> Sql.getJust variantId
            name <- graphName <$> Sql.getJust graphId

            let pdfName = name <> "-levels"
                missingResults (PatternFailed _) = logErrorN $ mconcat
                    [ "Missing results for graph \"", name
                    , "\", variant #", showSqlKey variantId ]

            handle missingResults . runPlotScript barPlotPlotConfig pdfName $
                streamQuery (variantToLevelTimePlotQuery variantId)
                .| C.map (bimap showText (nameImplementations regular))

        Totals -> runPlotScript barPlotPlotConfig "times-totals" $
            streamQuery (variantsToTimePlotQuery variants)
            .| C.map (second $ translatePair . toPair V.convert V.convert)

        VsOptimal -> runPlotScript barPlotPlotConfig "times-vs-optimal" $
            streamQuery variantQuery
            .| C.filter variantFilter
            .| C.mapM dataFromVariantInfo
            .| C.map (second $ translatePair . fmap V.convert)
  where
    filteredImpls = filterImpls barPlotImplementations
    filteredExt = filterExternal barPlotImplementations
    implMaps@Pair{regular} =
        toImplNames filteredImpls filteredExt globalPlotImpls

    translatePair :: Pair (Vector ImplTiming) -> Vector (Text, Double)
    translatePair x = mergePair $ nameImplementations <$> implMaps <*> x

    variantsToTimePlotQuery =
        timePlotQuery globalPlotAlgorithm globalPlotPlatform globalPlotCommit

    variantToLevelTimePlotQuery =
        levelTimePlotQuery globalPlotPlatform globalPlotCommit

    variantQuery = variantInfoQuery $ VariantInfoConfig
        { variantInfoAlgorithm = globalPlotAlgorithm
        , variantInfoPlatform = globalPlotPlatform
        , variantInfoCommit = globalPlotCommit
        , variantInfoVariantConfig = Nothing
        , variantInfoDataset = Nothing
        , variantInfoFilterIncomplete = False
        }

filterImpls :: Set Text -> IntMap Implementation -> IntMap Implementation
filterImpls textSet = IM.filter $ getAny . mconcat
    [ Any . (`S.member` textSet) . implementationName
    , Any . (Builtin==) . implementationType
    ]

filterExternal :: Set Text -> IntMap ExternalImpl -> IntMap ExternalImpl
filterExternal names = IM.filter ((`S.member` names) . externalImplName)

dataFromVariantInfo
    :: VariantInfo -> Region SqlM (Text, Pair (Vector ImplTiming))
dataFromVariantInfo VariantInfo{..} = do
    graphId <- variantGraphId <$> Sql.getJust variantId
    name <- graphName <$> Sql.getJust graphId
    return (name, Pair extendedTimings (V.convert variantExternalTimings))
  where
    extendedTimings = V.convert variantTimings
        `V.snoc` ImplTiming bestNonSwitchingImplId variantBestNonSwitching
        `V.snoc` ImplTiming optimalImplId variantOptimal

nameImplementations
    :: Generic.Vector v ImplTiming
    => IntMap Text
    -> v ImplTiming
    -> Vector (Text, Double)
nameImplementations impls = V.mapMaybe translate . V.convert
  where
    translate :: ImplTiming -> Maybe (Text, Double)
    translate (ImplTiming impl val) = (,val) <$> impls IM.!? fromIntegral impl

runPlotScript
    :: PlotConfig
    -> Text
    -> ConduitT () (Text, Vector (Text, Double)) (Region SqlM) ()
    -> SqlM ()
runPlotScript PlotConfig{..} plotName queryDataConduit
  | printStdout = doWithHandle stdout
  | otherwise = do
        plotProcess <- getBarPlotScript args
        withStdin plotProcess doWithHandle
  where
    args :: [String]
    args = [T.unpack plotName, axisName, show normalise, show slideFormat]

    doWithHandle :: Handle -> SqlM ()
    doWithHandle hnd = Sql.runRegionConduit $
        queryDataConduit .| do
            impls <- C.peek >>= \case
                Just (_, v) -> return $ V.map fst v
                Nothing -> logThrowM . PatternFailed $
                    "Expected at least one output row"

            liftIO . T.hPutStrLn hnd $ toColumnLabels impls
            C.mapM_ $ printGraph hnd impls

    toColumnLabels :: Vector Text -> Text
    toColumnLabels = mconcat . intersperse ":" . V.toList

    printGraph
        :: (MonadIO m, MonadLogger m, MonadThrow m)
        => Handle -> Vector Text -> (Text, Vector (Text, Double)) -> m ()
    printGraph hnd impls (graph, timingsPair)
        | mismatch = logThrowM $
            QueryResultMismatch (V.toList impls) (V.toList timingImpls)

        | otherwise = liftIO $ do
            T.hPutStr hnd $ graph <> " :"
            V.forM_ processedTimings $ \time ->
                hPutStr hnd $ " " ++ show time
            T.hPutStrLn hnd ""
      where
        mismatch :: Bool
        mismatch = not . V.and $ V.zipWith (==) impls timingImpls

        timingImpls :: Vector Text
        timings :: Vector Double
        (timingImpls, timings) = V.unzip timingsPair

        maxTime :: Double
        maxTime = V.maximum . V.filter (not . isInfinite) $ timings

        processedTimings :: Vector Double
        processedTimings
            | normalise = V.map (/ maxTime) timings
            | otherwise = timings
