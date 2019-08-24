{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MonadFailDesugaring #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
module Schema.Timers where

import Data.String.Interpolate.IsString (i)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import qualified Database.Persist.Sql as Sql
import Database.Persist.TH (persistUpperCase)
import qualified Database.Persist.TH as TH

import Schema.Utils (EntityDef, Int64, MonadMigrate, (.>))
import qualified Schema.Utils as Utils

import Schema.Implementation (ImplementationId)
import Schema.Platform (PlatformId)
import Schema.Variant (VariantId)
import Types

TH.share [TH.mkPersist TH.sqlSettings, TH.mkSave "schema"] [persistUpperCase|
TotalTimer
    platformId PlatformId
    variantId VariantId
    implId ImplementationId
    name Text
    minTime Double
    avgTime Double
    maxTime Double
    stdDev Double
    timestamp UTCTime
    wrongResult Hash Maybe
    Primary platformId variantId implId name
    deriving Eq Show

StepTimer
    platformId PlatformId
    variantId VariantId
    stepId Int
    implId ImplementationId
    name Text
    minTime Double
    avgTime Double
    maxTime Double
    stdDev Double
    timestamp UTCTime
    wrongResult Hash Maybe
    Primary platformId variantId stepId implId name
    deriving Eq Show
|]

migrations :: MonadMigrate m => Int64 -> m [EntityDef]
migrations = Utils.mkMigrationLookup
    [ 1 .> schema $ do
        Utils.executeMigrationSql [i|
ALTER TABLE 'TotalTimer' RENAME COLUMN 'gpuId' TO 'platformId'
|]
        Utils.executeMigrationSql [i|
ALTER TABLE 'StepTimer' RENAME COLUMN 'gpuId' TO 'platformId'
|]
    ]
