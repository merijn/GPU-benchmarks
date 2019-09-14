{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MonadFailDesugaring #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
module Schema.Variant where

import Database.Persist.TH (persistUpperCase)
import qualified Database.Persist.TH as TH

import Schema.Utils (EntityDef, Int64, MonadSql, (.=))
import qualified Schema.Utils as Utils
import Types

import Schema.Graph (GraphId)
import Schema.VariantConfig (VariantConfigId)
import qualified Schema.Variant.V0 as V0

TH.share [TH.mkPersist TH.sqlSettings, TH.mkSave "schema"] [persistUpperCase|
Variant
    graphId GraphId
    variantConfigId VariantConfigId
    result Hash Maybe
    propsStored Bool
    retryCount Int
    UniqVariant graphId variantConfigId
    deriving Eq Show
|]

migrations :: MonadSql m => Int64 -> m [EntityDef]
migrations = Utils.mkMigrationLookup [ 0 .= V0.schema, 7 .= schema ]
