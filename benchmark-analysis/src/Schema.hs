{-# LANGUAGE MonadFailDesugaring #-}
{-# LANGUAGE OverloadedStrings #-}
module Schema
    ( ByteString
    , Hash(..)
    , ImplType(..)
    , Model
    , PersistValue(..)
    , toPersistValue
    , Text
    , module Schema.Algorithm
    , module Schema.Graph
    , module Schema.Implementation
    , module Schema.Model
    , module Schema.Platform
    , module Schema.Properties
    , module Schema.Timers
    , module Schema.Variant
    , bestNonSwitchingImplId
    , predictedImplId
    , optimalImplId
    , getImplName
    , schemaVersion
    , currentSchema
    , schemaUpdateForVersion
    ) where

import Control.Monad.Reader (ReaderT)
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Database.Persist.Sql
    (EntityDef, Migration, PersistValue(..), SqlBackend, toPersistValue)

import Model (Model)
import Schema.Utils (MigrationAction, mkMigration)
import Types

import Schema.Algorithm hiding (migrations, schema)
import qualified Schema.Algorithm as Algorithm
import Schema.Graph hiding (migrations, schema)
import qualified Schema.Graph as Graph
import Schema.Implementation hiding (migrations, schema)
import qualified Schema.Implementation as Implementation
import Schema.Model hiding (migrations, schema)
import qualified Schema.Model as Model
import Schema.Platform hiding (migrations, schema)
import qualified Schema.Platform as Platform
import Schema.Properties hiding (migrations, schema)
import qualified Schema.Properties as Properties
import Schema.Timers hiding (migrations, schema)
import qualified Schema.Timers as Timers
import Schema.Variant hiding (migrations, schema)
import qualified Schema.Variant as Variant

bestNonSwitchingImplId :: Integral n => n
bestNonSwitchingImplId = -1

predictedImplId :: Integral n => n
predictedImplId = -2

optimalImplId :: Integral n => n
optimalImplId = -3

getImplName :: Implementation -> Text
getImplName (Implementation _ name prettyName _ _ _) =
  fromMaybe name prettyName

migrations :: [([EntityDef], Int64 -> MigrationAction)]
migrations =
    [ (Platform.schema, Platform.migrations)
    , (Graph.schema, Graph.migrations)
    , (Algorithm.schema, Algorithm.migrations)
    , (Implementation.schema, Implementation.migrations)
    , (Variant.schema, Variant.migrations)
    , (Properties.schema, Properties.migrations)
    , (Timers.schema, Timers.migrations)
    , (Model.schema, Model.migrations)
    ]

schemaVersion :: Int64
schemaVersion = 1

currentSchema :: Migration
currentSchema = mkMigration . map fst $ migrations

schemaUpdateForVersion :: Int64 -> ReaderT SqlBackend IO Migration
schemaUpdateForVersion n = mkMigration <$> mapM (($n) . snd) migrations
