{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
module Sql.Core
    ( DummySql
    , MonadSql(..)
    , SqlField
    , SqlRecord
    , Transaction(Transaction)
    , abortTransaction
    , runTransaction
    , runReadOnlyTransaction
    , runTransactionWithoutForeignKeys
    , tryAbortableTransaction
    , conduitQuery
    , executeSql
    , getMigration
    , querySingleValue
    , runMigrationQuiet
    , runMigrationUnsafeQuiet
    , selectKeys
    , selectSource
    , setPragma
    , setPragmaConn
    , showSqlKey
    , sinkQuery

    -- Re-exports
    , Entity(..)
    , EntityField
    , Filter
    , Key
    , Migration
    , PersistEntity
    , PersistField
    , PersistFieldSql
    , PersistRecordBackend
    , RawSqlite
    , SelectOpt(..)
    , SqlBackend
    , SqliteConnectionInfo
    , ToBackendKey
    , Unique
    , Update
    , (=.)
    , (==.)
    , (+=.)
    , (||.)
    , fieldLens
    , fromPersistValue
    , fromSqlKey
    , persistIdField
    , toSqlKey
    ) where

import Control.Monad (join, void)
import Control.Monad.Catch (MonadThrow, MonadCatch, handle, throwM)
import Control.Monad.Fail (MonadFail)
import Control.Monad.IO.Unlift (MonadIO)
import Control.Monad.Logger (MonadLogger, logErrorN)
import Control.Monad.Reader (ReaderT, asks, runReaderT, withReaderT)
import Control.Monad.Trans (MonadTrans, lift)
import Control.Monad.Trans.Resource (MonadResource, ResourceT, release)
import Data.Acquire (Acquire, allocateAcquire, mkAcquire)
import Data.Conduit (ConduitT, Void, (.|), runConduit)
import Data.Pool (Pool)
import Data.Text (Text)
import qualified Data.Text as T
import Database.Persist.Sqlite
    ( BackendCompatible
    , Entity(..)
    , EntityField
    , Filter
    , Key
    , Migration
    , PersistEntity
    , PersistField
    , PersistFieldSql
    , PersistRecordBackend
    , PersistValue
    , RawSqlite
    , SelectOpt(..)
    , Single(Single)
    , SqlBackend
    , SqliteConnectionInfo
    , ToBackendKey
    , Unique
    , Update
    , (=.)
    , (==.)
    , (+=.)
    , (||.)
    , fieldLens
    , fromPersistValue
    , fromSqlKey
    , persistIdField
    , toSqlKey
    )
import qualified Database.Persist.Sqlite as Sqlite

import Exceptions

class MonadResource m => MonadSql m where
    getConnFromPool :: m (Acquire (RawSqlite SqlBackend))
    getConnWithoutForeignKeysFromPool :: m (Acquire (RawSqlite SqlBackend))

instance MonadSql m => MonadSql (ConduitT a b m) where
    getConnFromPool = lift getConnFromPool
    getConnWithoutForeignKeysFromPool = lift getConnWithoutForeignKeysFromPool

instance MonadSql m => MonadSql (ReaderT r m) where
    getConnFromPool = lift getConnFromPool
    getConnWithoutForeignKeysFromPool = lift getConnWithoutForeignKeysFromPool

instance MonadSql m => MonadSql (ResourceT m) where
    getConnFromPool = lift getConnFromPool
    getConnWithoutForeignKeysFromPool = lift getConnWithoutForeignKeysFromPool

newtype DummySql a =
  DummySql (ReaderT (Pool (RawSqlite SqlBackend)) (ResourceT IO) a)
  deriving (Functor, Applicative, Monad, MonadIO, MonadResource)

instance MonadSql DummySql where
    getConnFromPool = DummySql $ asks Sqlite.acquireSqlConnFromPool
    getConnWithoutForeignKeysFromPool = getConnFromPool

newtype Transaction m r = Transaction (ReaderT (RawSqlite SqlBackend) m r)
  deriving
  ( Functor, Applicative, Monad, MonadCatch, MonadFail, MonadIO, MonadLogger
  , MonadResource, MonadThrow, MonadTrans
  )

type SqlRecord rec = (PersistRecordBackend rec (RawSqlite SqlBackend))
type SqlField rec field = (PersistField field, SqlRecord rec)

readOnlyConnection :: RawSqlite SqlBackend -> Acquire (RawSqlite SqlBackend)
readOnlyConnection conn = mkAcquire mkReadOnly mkReadWrite
  where
    mkReadOnly = conn <$ setPragmaConn "query_only" (1 :: Int) conn
    mkReadWrite _ = setPragmaConn "query_only" (0 :: Int) conn

abortTransaction :: MonadThrow m => Text -> Transaction m r
abortTransaction txt = Transaction . throwM $ AbortTransaction txt

runRawTransaction
    :: MonadSql m
    => m (Acquire (RawSqlite SqlBackend)) -> Transaction m r -> m r
runRawTransaction getConn (Transaction transaction) = do
    (key, conn) <- getConn >>= allocateAcquire
    runReaderT transaction conn <* release key

runTransaction :: MonadSql m => Transaction m r -> m r
runTransaction = runRawTransaction getConnFromPool

runReadOnlyTransaction :: MonadSql m => Transaction m r -> m r
runReadOnlyTransaction = runRawTransaction getReadOnlyConn
  where
    getReadOnlyConn = (>>= readOnlyConnection) <$> getConnFromPool

runTransactionWithoutForeignKeys :: MonadSql m => Transaction m r -> m r
runTransactionWithoutForeignKeys =
    runRawTransaction getConnWithoutForeignKeysFromPool

tryAbortableTransaction
    :: (MonadCatch m, MonadLogger m, MonadSql m) => Transaction m () -> m ()
tryAbortableTransaction = handle abortException . runTransaction
  where
    abortException :: MonadLogger m => AbortTransaction -> m ()
    abortException (AbortTransaction msg) =
      logErrorN $ "Transaction aborted: " <> msg

liftProjectPersist
    :: (BackendCompatible sup (RawSqlite SqlBackend), MonadSql m)
    => ReaderT sup IO a -> Transaction m a
liftProjectPersist =
    Transaction . Sqlite.liftPersist . withReaderT Sqlite.projectBackend

setPragma :: (MonadSql m, Show v) => Text -> v -> Transaction m ()
setPragma pragma val = Transaction $ Sqlite.rawExecute query []
  where
    query = "PRAGMA " <> pragma <> " = " <> T.pack (show val)

setPragmaConn
    :: (MonadIO m, Show v) => Text -> v -> RawSqlite SqlBackend -> m ()
setPragmaConn pragma val = runReaderT (Sqlite.rawExecute query [])
  where
    query = "PRAGMA " <> pragma <> " = " <> T.pack (show val)

executeSql :: MonadSql m => Text -> Transaction m ()
executeSql query = Transaction $ Sqlite.rawExecute query []

sinkQuery
    :: MonadResource m
    => Text
    -> [PersistValue]
    -> ConduitT [PersistValue] Void (Transaction m) r
    -> Transaction m r
sinkQuery query args sink = do
    (key, source) <- Transaction $ do
        acquireQuery <- Sqlite.rawQueryRes query args
        allocateAcquire acquireQuery

    runConduit (source .| sink) <* release key

selectKeys
    :: (MonadResource m, SqlRecord record)
    => [Filter record]
    -> [SelectOpt record]
    -> ConduitT (Key record) Void (Transaction m) r
    -> Transaction m r
selectKeys filts order sink = do
    (key, source) <- Transaction $ do
        acquireQuery <- Sqlite.selectKeysRes filts order
        allocateAcquire acquireQuery

    runConduit (source .| sink) <* release key

selectSource
    :: (MonadResource m, SqlRecord record)
    => [Filter record]
    -> [SelectOpt record]
    -> ConduitT (Entity record) Void (Transaction m) r
    -> Transaction m r
selectSource filts order sink = do
    (key, source) <- Transaction $ do
        acquireQuery <- Sqlite.selectSourceRes filts order
        allocateAcquire acquireQuery

    runConduit (source .| sink) <* release key

conduitQuery
    :: (MonadIO m, MonadSql n)
    => Text -> [PersistValue] -> n (Acquire (ConduitT () [PersistValue] m ()))
conduitQuery query args = do
    acquireConn <- getConnFromPool
    return $ do
        conn <- acquireConn >>= readOnlyConnection
        join $ runReaderT (Sqlite.rawQueryRes query args) conn

querySingleValue
    :: (MonadLogger m, MonadSql m, MonadThrow m, PersistField a)
    => Text -> [PersistValue] -> m a
querySingleValue query args = runTransaction . Transaction $ do
    result <- Sqlite.rawSql query args
    case result of
        [Single v] -> return v
        _ -> logThrowM $ ExpectedSingleValue query

getMigration :: (MonadSql m) => Migration -> Transaction m [Text]
getMigration = liftProjectPersist . Sqlite.getMigration

runMigrationQuiet :: (MonadSql m) => Migration -> Transaction m [Text]
runMigrationQuiet = liftProjectPersist . Sqlite.runMigrationQuiet

runMigrationUnsafeQuiet :: (MonadSql m) => Migration -> Transaction m ()
runMigrationUnsafeQuiet =
    void . liftProjectPersist . Sqlite.runMigrationUnsafeQuiet

showSqlKey :: ToBackendKey SqlBackend record => Key record -> Text
showSqlKey = T.pack . show . Sqlite.fromSqlKey
