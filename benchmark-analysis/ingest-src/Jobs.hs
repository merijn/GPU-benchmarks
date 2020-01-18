{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MonadFailDesugaring #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
module Jobs
    ( Validation(..)
    , (.>)
    , variantToPropertyJob
    , processProperty
    , missingRunToTimingJob
    , processTiming
    , validationMissingRuns
    , validateResults
    , cleanupValidation
    ) where

import BroadcastChan.Conduit
import qualified Control.Concurrent.STM as STM
import Control.Monad (unless, when)
import Crypto.Hash.Conduit (hashFile)
import qualified Data.ByteArray (convert)
import Data.Conduit (ConduitT, (.|), runConduit, yield)
import qualified Data.Conduit.Combinators as C
import qualified Data.Conduit.Text as C
import Data.Maybe (fromMaybe)
import Data.Semigroup (Max(..))
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)

import Core
import MissingQuery
import Parsers
import ProcessPool (Job, Result(..), makePropertyJob, makeTimingJob)
import qualified ProcessPool
import Query (runSqlQuery)
import qualified RuntimeData
import Schema
import Sql (Entity(..), Key, MonadSql, Transaction, (=.))
import qualified Sql
import qualified Sql.Transaction as SqlTrans
import Types (HashDigest)

computeHash :: MonadIO m => FilePath -> m Hash
computeHash path = do
    (digest :: HashDigest) <- hashFile path
    return . Hash . Data.ByteArray.convert $ digest

variantToPropertyJob
    :: Entity Variant
    -> ConduitT (Entity Variant)
                (Job (Key Algorithm, Key Graph, Maybe Hash, Maybe Int))
                SqlM
                ()
variantToPropertyJob
    (Entity varId (Variant graphId variantCfgId _ hash step hasProps retries)) =
        case hash of
            Nothing
                | retries < 5 && not hasProps && step == 0 -> yieldJob
                | hasProps -> logErrorN $
                    "Properties stored, but not result hash for variant #"
                    <> showSqlKey varId

                | not hasProps && step /= 0 -> logErrorN $
                    "No properties, but did find max steps for variant #"
                    <> showSqlKey varId

                | retries >= 5 -> logWarnN $
                    "Hash missing, but too many retries for variant #"
                    <> showSqlKey varId

                | otherwise -> logErrorN $
                    "Variant information for #" <> showSqlKey varId
                    <> " is in an inconsistent state!"

            Just _
                | retries < 5 && not hasProps && step == 0 -> do
                    logWarnN $ mconcat
                      [ "Found a stored result, but no properties for variant#"
                      , showSqlKey varId
                      ]
                    yieldJob

                | hasProps -> return ()

                | not hasProps && step /= 0 -> logErrorN $
                    "No properties, but did find max steps for variant #"
                    <> showSqlKey varId

                | retries >= 5 -> logWarnN $
                    "No properties, but too many retries for variant #"
                    <> showSqlKey varId

                | otherwise -> logErrorN $
                    "Variant information for #" <> showSqlKey varId
                    <> " is in an inconsistent state!"
  where
    maxStep | not hasProps && step == 0 = Nothing
            | otherwise = Just step

    yieldJob = do
        Graph _ path _ _ <- Sql.getJust graphId
        VariantConfig algoId _ flags _ <- Sql.getJust variantCfgId
        Algorithm algo _ <- Sql.getJust algoId
        yield . makePropertyJob (algoId,graphId,hash,maxStep) varId Nothing $
            [ "-a", algo, fromMaybe "" flags, path ]

processProperty
    :: Result (Key Algorithm, Key Graph, Maybe Hash, Maybe Int) -> SqlM ()
processProperty result@Result
  { resultValue=(algoId, _, _, _)
  , resultPropLog = Nothing
  , ..
  } = do
    ProcessPool.cleanupOutput result
    ProcessPool.cleanupTimings result
    logThrowM . GenericInvariantViolation $ mconcat
        [ "Found property run without property log file for algorithm #"
        , showSqlKey algoId, " variant #", showSqlKey resultVariant
        ]

processProperty result@Result
  { resultValue = (algoId, graphId, hash, maxStep)
  , resultOutput = (outputFile, _)
  , resultPropLog = Just (propLog, _)
  , ..
  } = do
    logDebugNS "Property#Start" resultLabel
    ProcessPool.cleanupTimings result
    resultHash <- computeHash outputFile

    SqlTrans.tryAbortableTransaction $ do
        loadProps <- case hash of
            Nothing -> True <$ SqlTrans.update resultVariant
                                    [VariantResult =. Just resultHash]

            Just prevHash | prevHash == resultHash -> return True
            _ -> False <$ logErrorN
                    ("Hash mismatch for variant: " <> showSqlKey resultVariant)

        ProcessPool.cleanupOutput result

        when loadProps $ do
            stepCount <- runConduit $
                C.sourceFile propLog
                .| C.decode C.utf8
                .| C.map (T.replace "," "")
                .| conduitParse property
                .| C.foldMapM insertProperty

            case (maxStep, stepCount) of
                (_, Nothing) -> logInfoN $ mconcat
                    [ "Did't find step count for algorithm #"
                    , showSqlKey algoId, " and variant #"
                    , showSqlKey resultVariant
                    ]

                (Nothing, Just (Max n)) ->
                        SqlTrans.update resultVariant [VariantMaxStepId =. n]

                (Just step, Just (Max n))
                    | n < step -> SqlTrans.abortTransaction $ mconcat
                        [ "Found less than expected step count for variant: "
                        , showSqlKey resultVariant
                        ]

                    | n > step -> SqlTrans.abortTransaction $ mconcat
                        [ "Found more than expected step count for variant: "
                        , showSqlKey resultVariant
                        ]

                    | otherwise -> return ()

            SqlTrans.update resultVariant [VariantPropsStored =. True]

        ProcessPool.cleanupProperties result

    logDebugNS "Property#End" resultLabel
  where
    insertProperty :: Property -> Transaction SqlM (Maybe (Max Int))
    insertProperty (GraphProperty name val) = Nothing <$ do
        SqlTrans.insertUniq $ GraphProp graphId name val

    insertProperty (StepProperty n _ _)
        | Just i <- maxStep
        , n > i = SqlTrans.abortTransaction $ mconcat
            [ "Found step property with a step count (", showText n
            , ") larger than stored maximum (", showText i, ") for algorithm #"
            , showSqlKey algoId, " variant #", showSqlKey resultVariant
            ]

    insertProperty (StepProperty n name val) = Just (Max n) <$ do
        SqlTrans.insertUniq $ StepProp algoId name
        SqlTrans.insertUniq $ StepPropValue algoId resultVariant n name val

    insertProperty Prediction{} = return Nothing

missingRunToTimingJob
    :: (MonadLogger m, MonadResource m, MonadSql m)
    => Key Platform
    -> MissingRun ExtraVariantInfo
    -> ConduitT (MissingRun ExtraVariantInfo)
                (Job (Key Algorithm, Key Implementation, Hash, Int))
                m
                ()
missingRunToTimingJob platformId MissingRun{..} = case missingRunExtraInfo of
    ExtraVariantInfo Nothing _ -> logErrorN . mconcat $
        [ "Algorithm #", showSqlKey missingRunAlgorithmId
        , " results missing for variant #", showSqlKey missingRunVariantId
        ]

    ExtraVariantInfo (Just hash) steps -> yield $ makeTimingJob
            (missingRunAlgorithmId, missingRunImplId, hash, steps)
            missingRunVariantId
            (Just (platformId, missingRunImplName))
            missingRunArgs

processTiming
    :: (MonadCatch m, MonadLogger m, MonadResource m, MonadSql m)
    => Key RunConfig
    -> CommitId
    -> Result (Key Algorithm, Key Implementation, Hash, Int)
    -> m ()
processTiming runConfigId commit result@Result{..} = do
    logDebugNS "Timing#Start " resultLabel
    time <- liftIO getCurrentTime
    resultHash <- computeHash outputFile
    ProcessPool.cleanupProperties result
    ProcessPool.cleanupOutput result

    if commit /= resultAlgorithmVersion
       then logErrorN $ mconcat
        [ "Unexpected algorithm version for implementation #"
        , showSqlKey implId, "! Expected commit ", getCommitId commit
        , " found commit ", getCommitId resultAlgorithmVersion
        ]
       else SqlTrans.tryAbortableTransaction $ do
        let validated = resultHash == hash

        runId <- SqlTrans.insert $
            Run runConfigId resultVariant implId algoId time validated

        unless validated $ do
            logErrorN . mconcat $
                [ "Implementation #", showSqlKey implId
                , " has wrong result hash for variant #"
                , showSqlKey resultVariant
                , " for run config #", showSqlKey runConfigId
                ]

        runConduit $
            C.sourceFile timingFile
            .| C.decode C.utf8
            .| C.map (T.replace "," "")
            .| conduitParse timer
            .| C.mapM_ (insertTiming runId)

        logDebugNS "Timing#End" resultLabel

    ProcessPool.cleanupTimings result
  where
    (algoId, implId, hash, maxStep) = resultValue
    timingFile = T.unpack resultLabel <> ".timings"
    outputFile = T.unpack resultLabel <> ".output"

    insertTiming
        :: (MonadThrow m, MonadSql m) => Key Run -> Timer -> Transaction m ()
    insertTiming runId (TotalTiming Timing{..}) = SqlTrans.insert_ $
        TotalTimer runId name minTime avgTime maxTime stddev

    insertTiming _ (StepTiming n _) | n > maxStep =
        SqlTrans.abortTransaction $ mconcat
            [ "Found step timing with a step count (", showText n
            , ") larger than stored maximum (", showText maxStep
            , ") for algorithm #", showSqlKey algoId, " variant #"
            , showSqlKey resultVariant
            ]

    insertTiming runId (StepTiming n Timing{..}) = SqlTrans.insert_ $
        StepTimer runId n name minTime avgTime maxTime stddev

data Validation = Validation
    { cleanData :: SqlM ()
    , originalCommit :: CommitId
    , referenceResult :: FilePath
    , runId :: Key Run
    }

validationMissingRuns
    :: Key Platform
    -> Result ValidationVariant
    -> ConduitT (Result ValidationVariant) (Job Validation) SqlM ()
validationMissingRuns platformId result@Result{..} = do
    ProcessPool.cleanupTimings result
    ProcessPool.cleanupProperties result
    refCounter <- liftIO $ STM.newTVarIO validationMissingCount

    let onCompletion :: SqlM ()
        onCompletion = do
            count <- liftIO . STM.atomically $ do
                STM.modifyTVar' refCounter (subtract 1)
                STM.readTVar refCounter

            when (count == 0) $ ProcessPool.cleanupOutput result

        mkValidation :: Key Run -> Validation
        mkValidation = Validation onCompletion validationCommit outputFile

        toValidationJob :: MissingRun (Key Run) -> Job Validation
        toValidationJob MissingRun{..} = makeTimingJob
            (mkValidation missingRunExtraInfo)
            missingRunVariantId
            (Just (platformId, missingRunImplName))
            missingRunArgs

    runSqlQuery (validationRunQuery platformId resultValue)
        .| C.map toValidationJob
  where
    ValidationVariant{..} = resultValue
    outputFile = T.unpack resultLabel <> ".output"

validateResults
    :: Int -> ConduitT (Result Validation) (Result Validation) SqlM ()
validateResults numProcs = do
    validate <- RuntimeData.getOutputChecker
    parMapM (Simple Terminate) numProcs (process validate)
  where
    process
        :: (FilePath -> FilePath -> SqlM Bool)
        -> Result Validation
        -> SqlM (Result Validation)
    process check res@Result{resultAlgorithmVersion, resultOutput, resultValue}
      | originalCommit /= resultAlgorithmVersion = do
            res <$ logErrorN "Result validation used wrong algorithm version!"
      | otherwise = do
            result <- check referenceResult outputFile
            ts <- liftIO $ getCurrentTime

            when result $ do
                Sql.update runId [RunValidated =. True, RunTimestamp =. ts]
            return res
      where
        Validation{..} = resultValue
        (outputFile, _) = resultOutput

cleanupValidation :: Result Validation -> SqlM ()
cleanupValidation result@Result{resultValue = Validation{..}} = do
    ProcessPool.cleanupOutput result
    ProcessPool.cleanupTimings result
    ProcessPool.cleanupProperties result
    cleanData
