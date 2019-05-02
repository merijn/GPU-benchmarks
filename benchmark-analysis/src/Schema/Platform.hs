{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MonadFailDesugaring #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
module Schema.Platform where

import Data.String.Interpolate.IsString (i)
import Data.Text (Text)
import qualified Database.Persist.Sql as Sql
import Database.Persist.TH (persistUpperCase)
import qualified Database.Persist.TH as TH

import Schema.Utils (Int64, MigrationAction, (.=), mkMigrationLookup)

TH.share [TH.mkPersist TH.sqlSettings, TH.mkSave "schema"] [persistUpperCase|
Platform
    name Text
    prettyName Text Maybe
    UniqPlatform name
    deriving Eq Show
|]

migrations :: Int64 -> MigrationAction
migrations = mkMigrationLookup schema
    [ 0 .= schema $ do
        Sql.rawExecute [i|
ALTER TABLE 'GPU' RENAME TO 'Platform'
|] []
    ]
