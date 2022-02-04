{-# LANGUAGE UndecidableInstances #-}
module IHP.DataSync.Controller where

import IHP.ControllerPrelude
import qualified Control.Exception as Exception
import qualified IHP.Log as Log
import qualified Data.Aeson as Aeson

import Data.Aeson.TH
import Data.Aeson
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.ToField as PG
import qualified Database.PostgreSQL.Simple.Types as PG
import qualified Data.HashMap.Strict as HashMap
import qualified Data.UUID.V4 as UUID
import qualified Control.Concurrent.MVar as MVar
import IHP.DataSync.Types
import IHP.DataSync.RowLevelSecurity
import IHP.DataSync.DynamicQuery
import IHP.DataSync.DynamicQueryCompiler
import qualified IHP.DataSync.ChangeNotifications as ChangeNotifications
import IHP.DataSync.REST.Controller (aesonValueToPostgresValue)
import qualified Data.ByteString.Char8 as ByteString
import qualified IHP.PGListener as PGListener
import IHP.ApplicationContext
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Pool as Pool

instance (
    PG.ToField (PrimaryKey (GetTableName CurrentUserRecord))
    , Show (PrimaryKey (GetTableName CurrentUserRecord))
    , HasNewSessionUrl CurrentUserRecord
    , Typeable CurrentUserRecord
    , HasField "id" CurrentUserRecord (Id' (GetTableName CurrentUserRecord))
    ) => WSApp DataSyncController where
    initialState = DataSyncController

    run = do
        setState DataSyncReady { subscriptions = HashMap.empty, transactions = HashMap.empty }

        ensureRLSEnabled <- makeCachedEnsureRLSEnabled
        installTableChangeTriggers <- ChangeNotifications.makeCachedInstallTableChangeTriggers

        let pgListener = ?applicationContext |> get #pgListener

        let
            handleMessage :: DataSyncMessage -> IO ()
            handleMessage DataSyncQuery { query, requestId, transactionId } = do
                ensureRLSEnabled (get #table query)

                let (theQuery, theParams) = compileQuery query

                result :: [[Field]] <- sqlQueryWithRLSAndTransactionId transactionId theQuery theParams

                sendJSON DataSyncResult { result, requestId }
            
            handleMessage CreateDataSubscription { query, requestId } = do
                tableNameRLS <- ensureRLSEnabled (get #table query)

                subscriptionId <- UUID.nextRandom

                let (theQuery, theParams) = compileQuery query

                result :: [[Field]] <- sqlQueryWithRLS theQuery theParams

                let tableName = get #table query

                -- We need to keep track of all the ids of entities we're watching to make
                -- sure that we only send update notifications to clients that can actually
                -- access the record (e.g. if a RLS policy denies access)
                let watchedRecordIds = recordIds result

                -- Store it in IORef as an INSERT requires us to add an id
                watchedRecordIdsRef <- newIORef (Set.fromList watchedRecordIds)

                -- Make sure the database triggers are there
                installTableChangeTriggers tableNameRLS

                let callback notification = case notification of
                            ChangeNotifications.DidInsert { id } -> do
                                -- The new record could not be accessible to the current user with a RLS policy
                                -- E.g. it could be a new record in a 'projects' table, but the project belongs
                                -- to a different user, and thus the current user should not be able to see it.
                                --
                                -- The new record could also be not part of the WHERE condition of the initial query.
                                -- Therefore we need to use the subscriptions WHERE condition to fetch the new record here.
                                --
                                -- To honor the RLS policies we therefore need to fetch the record as the current user
                                -- If the result set is empty, we know the record is not accesible to us
                                newRecord :: [[Field]] <- sqlQueryWithRLS ("SELECT * FROM (" <> theQuery <> ") AS records WHERE records.id = ? LIMIT 1") (theParams <> [PG.toField id])

                                case headMay newRecord of
                                    Just record -> do
                                        -- Add the new record to 'watchedRecordIdsRef'
                                        -- Otherwise the updates and deletes will not be dispatched to the client
                                        modifyIORef' watchedRecordIdsRef (Set.insert id)

                                        sendJSON DidInsert { subscriptionId, record }
                                    Nothing -> pure ()
                            ChangeNotifications.DidUpdate { id, changeSet } -> do
                                -- Only send the notifcation if the deleted record was part of the initial
                                -- results set
                                isWatchingRecord <- Set.member id <$> readIORef watchedRecordIdsRef
                                when isWatchingRecord do
                                    sendJSON DidUpdate { subscriptionId, id, changeSet = changesToValue changeSet }
                            ChangeNotifications.DidDelete { id } -> do
                                -- Only send the notifcation if the deleted record was part of the initial
                                -- results set
                                isWatchingRecord <- Set.member id <$> readIORef watchedRecordIdsRef
                                when isWatchingRecord do
                                    sendJSON DidDelete { subscriptionId, id }


                channelSubscription <- pgListener
                        |> PGListener.subscribeJSON (ChangeNotifications.channelName tableNameRLS) callback

                modifyIORef' ?state (\state -> state |> modify #subscriptions (HashMap.insert subscriptionId Subscription { id = subscriptionId, channelSubscription }))

                sendJSON DidCreateDataSubscription { subscriptionId, requestId, result }

            handleMessage DeleteDataSubscription { requestId, subscriptionId } = do
                DataSyncReady { subscriptions } <- getState
                let maybeSubscription :: Maybe Subscription = HashMap.lookup subscriptionId subscriptions
                
                -- Cancel table watcher
                case maybeSubscription of
                    Just subscription -> pgListener |> PGListener.unsubscribe (get #channelSubscription subscription)
                    Nothing -> pure ()

                modifyIORef' ?state (\state -> state |> modify #subscriptions (HashMap.delete subscriptionId))

                sendJSON DidDeleteDataSubscription { subscriptionId, requestId }

            handleMessage CreateRecordMessage { table, record, requestId, transactionId }  = do
                ensureRLSEnabled table

                let query = "INSERT INTO ? ? VALUES ? RETURNING *"
                let columns = record
                        |> HashMap.keys
                        |> map fieldNameToColumnName

                let values = record
                        |> HashMap.elems
                        |> map aesonValueToPostgresValue

                let params = (PG.Identifier table, PG.In (map PG.Identifier columns), PG.In values)
                
                result :: [[Field]] <- sqlQueryWithRLSAndTransactionId transactionId query params

                case result of
                    [record] -> sendJSON DidCreateRecord { requestId, record }
                    otherwise -> error "Unexpected result in CreateRecordMessage handler"

                pure ()
            
            handleMessage CreateRecordsMessage { table, records, requestId, transactionId }  = do
                ensureRLSEnabled table

                let query = "INSERT INTO ? ? ? RETURNING *"
                let columns = records
                        |> head
                        |> \case
                            Just value -> value
                            Nothing -> error "Atleast one record is required"
                        |> HashMap.keys
                        |> map fieldNameToColumnName

                let values = records
                        |> map (\object ->
                                object
                                |> HashMap.elems
                                |> map aesonValueToPostgresValue
                            )
                        

                let params = (PG.Identifier table, PG.In (map PG.Identifier columns), PG.Values [] values)

                records :: [[Field]] <- sqlQueryWithRLSAndTransactionId transactionId query params

                sendJSON DidCreateRecords { requestId, records }

                pure ()

            handleMessage UpdateRecordMessage { table, id, patch, requestId, transactionId } = do
                ensureRLSEnabled table

                let columns = patch
                        |> HashMap.keys
                        |> map fieldNameToColumnName
                        |> map PG.Identifier

                let values = patch
                        |> HashMap.elems
                        |> map aesonValueToPostgresValue

                let keyValues = zip columns values

                let setCalls = keyValues
                        |> map (\_ -> "? = ?")
                        |> ByteString.intercalate ", "
                let query = "UPDATE ? SET " <> setCalls <> " WHERE id = ? RETURNING *"

                let params = [PG.toField (PG.Identifier table)]
                        <> (join (map (\(key, value) -> [PG.toField key, value]) keyValues))
                        <> [PG.toField id]

                result :: [[Field]] <- sqlQueryWithRLSAndTransactionId transactionId (PG.Query query) params
                
                case result of
                    [record] -> sendJSON DidUpdateRecord { requestId, record }
                    otherwise -> error "Unexpected result in UpdateRecordMessage handler"

                pure ()

            handleMessage UpdateRecordsMessage { table, ids, patch, requestId, transactionId } = do
                ensureRLSEnabled table

                let columns = patch
                        |> HashMap.keys
                        |> map fieldNameToColumnName
                        |> map PG.Identifier

                let values = patch
                        |> HashMap.elems
                        |> map aesonValueToPostgresValue

                let keyValues = zip columns values

                let setCalls = keyValues
                        |> map (\_ -> "? = ?")
                        |> ByteString.intercalate ", "
                let query = "UPDATE ? SET " <> setCalls <> " WHERE id IN ? RETURNING *"

                let params = [PG.toField (PG.Identifier table)]
                        <> (join (map (\(key, value) -> [PG.toField key, value]) keyValues))
                        <> [PG.toField (PG.In ids)]

                records <- sqlQueryWithRLSAndTransactionId transactionId (PG.Query query) params
                
                sendJSON DidUpdateRecords { requestId, records }

                pure ()
            
            handleMessage DeleteRecordMessage { table, id, requestId, transactionId } = do
                ensureRLSEnabled table

                sqlExecWithRLSAndTransactionId transactionId "DELETE FROM ? WHERE id = ?" (PG.Identifier table, id)

                sendJSON DidDeleteRecord { requestId }
            
            handleMessage DeleteRecordsMessage { table, ids, requestId, transactionId } = do
                ensureRLSEnabled table

                sqlExecWithRLSAndTransactionId transactionId "DELETE FROM ? WHERE id IN ?" (PG.Identifier table, PG.In ids)

                sendJSON DidDeleteRecords { requestId }

            handleMessage StartTransaction { requestId } = do
                ensureBelowTransactionLimit

                transactionId <- UUID.nextRandom
                
                (connection, localPool) <- ?modelContext
                        |> get #connectionPool
                        |> Pool.takeResource

                let transaction = DataSyncTransaction
                        { id = transactionId
                        , connection
                        , releaseConnection = Pool.putResource localPool connection
                        }

                let globalModelContext = ?modelContext
                let ?modelContext = globalModelContext { transactionConnection = Just connection } in sqlExecWithRLS "BEGIN" ()

                modifyIORef' ?state (\state -> state |> modify #transactions (HashMap.insert transactionId transaction))

                sendJSON DidStartTransaction { requestId, transactionId }

            handleMessage RollbackTransaction { requestId, id } = do
                sqlExecWithRLSAndTransactionId (Just id) "ROLLBACK" ()

                closeTransaction id

                sendJSON DidRollbackTransaction { requestId, transactionId = id }

            handleMessage CommitTransaction { requestId, id } = do
                sqlExecWithRLSAndTransactionId (Just id) "COMMIT" ()

                closeTransaction id

                sendJSON DidCommitTransaction { requestId, transactionId = id }



        forever do
            message <- Aeson.eitherDecodeStrict' <$> receiveData @ByteString

            case message of
                Right decodedMessage -> do
                    let requestId = get #requestId decodedMessage

                    -- Handle the messages in an async way
                    -- This increases throughput as multiple queries can be fetched
                    -- in parallel
                    async do
                        result <- Exception.try (handleMessage decodedMessage)

                        case result of
                            Left (e :: Exception.SomeException) -> do
                                let errorMessage = case fromException e of
                                        Just (enhancedSqlError :: EnhancedSqlError) -> cs (get #sqlErrorMsg (get #sqlError enhancedSqlError))
                                        Nothing -> cs (displayException e)
                                Log.error (tshow e)
                                sendJSON DataSyncError { requestId, errorMessage }
                            Right result -> pure ()

                    pure ()
                Left errorMessage -> sendJSON FailedToDecodeMessageError { errorMessage = cs errorMessage }

    onClose = cleanupAllSubscriptions

cleanupAllSubscriptions :: _ => (?state :: IORef DataSyncController, ?applicationContext :: ApplicationContext) => IO ()
cleanupAllSubscriptions = do
    state <- getState
    let pgListener = ?applicationContext |> get #pgListener

    case state of
        DataSyncReady { subscriptions, transactions } -> do
            let channelSubscriptions = subscriptions
                    |> HashMap.elems
                    |> map (get #channelSubscription)
            forEach channelSubscriptions \channelSubscription -> do
                pgListener |> PGListener.unsubscribe channelSubscription

            forEach (HashMap.elems transactions) (get #releaseConnection)

            pure ()
        _ -> pure ()

changesToValue :: [ChangeNotifications.Change] -> Value
changesToValue changes = object (map changeToPair changes)
    where
        changeToPair ChangeNotifications.Change { col, new } = (columnNameToFieldName col) .= new

queryFieldNamesToColumnNames :: SQLQuery -> SQLQuery
queryFieldNamesToColumnNames sqlQuery = sqlQuery
        |> modify #orderByClause (map convertOrderByClause)
    where
        convertOrderByClause OrderByClause { orderByColumn, orderByDirection } = OrderByClause { orderByColumn = cs (fieldNameToColumnName (cs orderByColumn)), orderByDirection }


runInModelContextWithTransaction :: (?state :: IORef DataSyncController, _) => ((?modelContext :: ModelContext) => IO result) -> Maybe UUID -> IO result
runInModelContextWithTransaction function (Just transactionId) = do
    let globalModelContext = ?modelContext

    DataSyncTransaction { connection } <- findTransactionById transactionId
    let
            ?modelContext = globalModelContext { transactionConnection = Just connection }
        in
            function
runInModelContextWithTransaction function Nothing = function

findTransactionById :: (?state :: IORef DataSyncController) => UUID -> IO DataSyncTransaction
findTransactionById transactionId = do
    transactions <- get #transactions <$> readIORef ?state
    case HashMap.lookup transactionId transactions of
        Just transaction -> pure transaction
        Nothing -> error "No transaction with that id"

closeTransaction transactionId = do
    DataSyncTransaction { releaseConnection } <- findTransactionById transactionId
    modifyIORef' ?state (\state -> state |> modify #transactions (HashMap.delete transactionId))
    releaseConnection

-- | Allow max 10 concurrent transactions per connection to avoid running out of database connections
--
-- Each transaction removes a database connection from the connection pool. If we don't limit the transactions,
-- a single user could take down the application by starting more than 'IHP.FrameworkConfig.DBPoolMaxConnections'
-- concurrent transactions. Then all database connections are removed from the connection pool and further database
-- queries for other users will fail.
--
ensureBelowTransactionLimit :: (?state :: IORef DataSyncController) => IO ()
ensureBelowTransactionLimit = do
    transactions <- get #transactions <$> readIORef ?state
    let transactionCount = HashMap.size transactions
    let maxTransactionsPerConnection = 10
    when (transactionCount >= maxTransactionsPerConnection) do
        error ("You've reached the transaction limit of " <> tshow maxTransactionsPerConnection <> " transactions")

sqlQueryWithRLSAndTransactionId ::
    ( ?modelContext :: ModelContext
    , PG.ToRow parameters
    , ?context :: ControllerContext
    , userId ~ Id CurrentUserRecord
    , Show (PrimaryKey (GetTableName CurrentUserRecord))
    , HasNewSessionUrl CurrentUserRecord
    , Typeable CurrentUserRecord
    , ?context :: ControllerContext
    , HasField "id" CurrentUserRecord (Id' (GetTableName CurrentUserRecord))
    , PG.ToField userId
    , FromRow result
    , ?state :: IORef DataSyncController
    ) => Maybe UUID -> PG.Query -> parameters -> IO [result]
sqlQueryWithRLSAndTransactionId transactionId theQuery theParams = runInModelContextWithTransaction (sqlQueryWithRLS theQuery theParams) transactionId

sqlExecWithRLSAndTransactionId ::
    ( ?modelContext :: ModelContext
    , PG.ToRow parameters
    , ?context :: ControllerContext
    , userId ~ Id CurrentUserRecord
    , Show (PrimaryKey (GetTableName CurrentUserRecord))
    , HasNewSessionUrl CurrentUserRecord
    , Typeable CurrentUserRecord
    , ?context :: ControllerContext
    , HasField "id" CurrentUserRecord (Id' (GetTableName CurrentUserRecord))
    , PG.ToField userId
    , ?state :: IORef DataSyncController
    ) => Maybe UUID -> PG.Query -> parameters -> IO Int64
sqlExecWithRLSAndTransactionId transactionId theQuery theParams = runInModelContextWithTransaction (sqlExecWithRLS theQuery theParams) transactionId

$(deriveFromJSON defaultOptions 'DataSyncQuery)
$(deriveToJSON defaultOptions 'DataSyncResult)

instance SetField "subscriptions" DataSyncController (HashMap UUID Subscription) where
    setField subscriptions record = record { subscriptions }

instance SetField "transactions" DataSyncController (HashMap UUID DataSyncTransaction) where
    setField transactions record = record { transactions }