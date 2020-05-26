{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}
module StepQuery where

import Control.Monad.ST (runST)
import Data.Ord (comparing)
import Data.String.Interpolate.IsString (i)
import qualified Data.Vector.Algorithms.Insertion as V
import Data.Vector.Storable (Vector)
import qualified Data.Vector.Storable as VS

import Core
import Query
import Schema
import Utils.ImplTiming (ImplTiming(implTimingImpl))
import Utils.PropValue (PropValue)
import Utils.Vector (byteStringToVector)

data StepInfoConfig = StepInfoConfig
    { stepInfoAlgorithm :: Key Algorithm
    , stepInfoPlatform :: Key Platform
    , stepInfoCommit :: CommitId
    , stepInfoFilterIncomplete :: Bool
    , stepInfoTimestamp :: UTCTime
    } deriving (Show)

data StepInfo =
  StepInfo
    { stepProps :: {-# UNPACK #-} !(Vector PropValue)
    , stepBestImpl :: {-# UNPACK #-} !Int64
    , stepVariantId :: {-# UNPACK #-} !(Key Variant)
    , stepId :: {-# UNPACK #-} !Int64
    , stepTimings :: {-# UNPACK #-} !(Vector ImplTiming)
    } deriving (Show)

sortStepTimings :: StepInfo -> StepInfo
sortStepTimings info@StepInfo{..} =
    info { stepTimings = sortVector stepTimings }
  where
    sortVector :: Vector ImplTiming -> Vector ImplTiming
    sortVector vec = runST $ do
        mvec <- VS.thaw vec
        V.sortBy (comparing implTimingImpl) mvec
        VS.unsafeFreeze mvec

stepInfoQuery :: StepInfoConfig -> Key Variant -> Query StepInfo
stepInfoQuery StepInfoConfig{..} variantId =
    Query{convert = Simple converter, ..}
  where
    queryName :: Text
    queryName = "infoStepQuery"

    converter :: MonadConvert m => [PersistValue] -> m StepInfo
    converter
        [ PersistInt64 (toSqlKey -> stepVariantId)
        , PersistInt64 stepId
        , PersistInt64 stepBestImpl
        , PersistByteString (byteStringToVector -> stepTimings)
        , PersistByteString (byteStringToVector -> stepProps)
        ]
        = return StepInfo{..}

    converter actualValues = logThrowM $ QueryResultUnparseable actualValues
        [ SqlInt64, SqlInt64, SqlInt64, SqlBlob, SqlBlob ]

    commonTableExpressions :: [CTE]
    commonTableExpressions =
      [ CTE
        { cteParams =
            [ toPersistValue stepInfoAlgorithm
            , toPersistValue variantId
            , toPersistValue variantId
            ]
        , cteQuery = [i|
PropIndices AS (
    SELECT PropertyName.id AS propId
         , ROW_NUMBER() OVER (ORDER BY PropertyName.id) AS idx
         , COUNT() OVER () AS count
    FROM PropertyName, Algorithm
    LEFT JOIN StepProp
    ON PropertyName.id = StepProp.propId
    WHERE NOT isStepProp OR (StepProp.algorithmId = ?)
),
EmptyPropVector(emptyProps) AS (
    SELECT init_key_value_vector_nan(propId, idx, count)
    FROM PropIndices
),
GraphPropVector(variantId, graphProps) AS (
    SELECT Variant.id
         , update_key_value_vector(emptyProps, idx, propId, value)
    FROM Variant, EmptyPropVector
    INNER JOIN GraphPropValue USING (graphId)
    INNER JOIN PropIndices USING (propId)
    GROUP BY Variant.id
    HAVING Variant.id = ?
),
StepProps(variantId, stepId, stepProps) AS (
    SELECT variantId, stepId
         , update_key_value_vector(graphProps, idx, propId, value)
    FROM GraphPropVector
    INNER JOIN StepPropValue USING (variantId)
    INNER JOIN PropIndices USING (propId)
    GROUP BY variantId, stepId
    HAVING variantId = ?
)|]
        }

      , [toPersistValue stepInfoAlgorithm] `inCTE` [i|
IndexedImpls(idx, implId, type, count) AS (
    SELECT ROW_NUMBER() OVER ()
         , Implementation.id
         , type
         , COUNT() OVER ()
    FROM Implementation
    WHERE algorithmId = ?
),

ImplVector(implTiming) AS (
    SELECT init_key_value_vector(implId, idx, count)
    FROM IndexedImpls
)|]
      ]

    params :: [PersistValue]
    params =
        [ toPersistValue stepInfoTimestamp
        , toPersistValue stepInfoAlgorithm
        , toPersistValue stepInfoAlgorithm
        , toPersistValue stepInfoPlatform
        , toPersistValue stepInfoCommit
        , toPersistValue $ not stepInfoFilterIncomplete
        ]

    queryText = [i|
SELECT StepProps.variantId
     , StepProps.stepId
     , min_key(Impls.implId, avgTime, maxTime, minTime)
       FILTER (WHERE Impls.type == 'Core')
     , update_key_value_vector(implTiming, idx, Impls.implId, avgTime)
     , StepProps.stepProps
FROM StepProps, ImplVector

INNER JOIN Run USING (variantId)
INNER JOIN RunConfig
ON RunConfig.id = Run.runConfigId

INNER JOIN StepTimer
ON StepTimer.runId = Run.id

INNER JOIN IndexedImpls AS Impls USING (implId)

WHERE Run.validated = 1
AND Run.timestamp < ?
AND Run.algorithmId = ?
AND RunConfig.algorithmId = ?
AND RunConfig.platformId = ?
AND RunConfig.algorithmVersion = ?

GROUP BY StepProps.variantId, StepProps.stepId
HAVING ? OR COUNT(Run.id) = MAX(Impls.count)
ORDER BY StepProps.variantId, StepProps.stepId ASC|]
