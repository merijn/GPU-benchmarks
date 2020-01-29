{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MonadFailDesugaring #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
module Schema.Graph.V0 where

import Data.Text (Text)
import qualified Database.Persist.Sql as Sql
import Database.Persist.TH (persistUpperCase)
import qualified Database.Persist.TH as TH

TH.share [TH.mkPersist TH.sqlSettings, TH.mkSave "schema"] [persistUpperCase|
Graph
    name Text
    dataset Text
    path Text
    prettyName Text Maybe
    UniqGraph path
    UniqGraphName path dataset
    deriving Eq Show
|]
