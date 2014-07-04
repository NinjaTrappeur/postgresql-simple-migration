module Database.PostgreSQL.Simple.Migration
    ( runMigrations
    , initializeMigrations
    , MigrationContext(..)
    , SchemaVersion(..)
    ) where

import           Control.Monad                    (liftM, void, when)
import qualified Crypto.Hash.MD5                  as MD5 (hash)
import qualified Data.ByteString                  as BS (ByteString, readFile)
import qualified Data.ByteString.Base64           as B64 (encode)
import           Data.List                        (isPrefixOf, sort)
import           Data.Monoid                      (mconcat)
import           Database.PostgreSQL.Simple       (Connection, Only (..),
                                                   execute, execute_, query,
                                                   withTransaction)
import           Database.PostgreSQL.Simple.Types (Query (..))
import           System.Directory                 (getDirectoryContents)

runMigrations :: MigrationContext -> IO (MigrationResult String)
runMigrations (MigrationContext dir verbose con) =
    liftM (filter (\x -> not $ "." `isPrefixOf` x)) (getDirectoryContents dir) >>= go . sort
    where
        go [] = return MigrationSuccess
        go (f:fs) =
            runMigration con verbose dir f >>= \r -> case r of
                MigrationError _ ->
                    return r
                MigrationSuccess ->
                    go fs

initializeMigrations :: MigrationContext -> IO (MigrationResult String)
initializeMigrations (MigrationContext _dir verbose con) =
    initializeSchema con verbose >> return MigrationSuccess

runMigration :: Connection -> Bool -> FilePath -> FilePath -> IO (MigrationResult String)
runMigration con verbose dir filename = withTransaction con $ do
    let path = dir ++ "/" ++ filename
    contents <- BS.readFile path
    let checksum = md5Hash contents
    checkFile con filename checksum >>= \r -> case r of
        ScriptOk -> do
            when verbose $ putStrLn $ "Ok:\t" ++ filename
            return MigrationSuccess
        ScriptMissing -> do
            void $ execute_ con (Query contents)
            void $ execute con q (filename, checksum)
            when verbose $ putStrLn $ "Execute:\t" ++ filename
            return MigrationSuccess
        ScriptModified _ -> do
            when verbose $ putStrLn $ "Fail:\t" ++ filename
            return (MigrationError filename)
    where
        q = "insert into schema_migrations(filename, checksum) values(?, ?) "

initializeSchema :: Connection -> Bool -> IO ()
initializeSchema con verbose = do
    when verbose $ putStrLn "Initializing schema"
    void $ execute_ con $ mconcat
        [ "create table if not exists schema_migrations "
        , "( filename varchar(512) not null"
        , ", checksum varchar(32) not null"
        , ", executed_at timestamp without time zone not null default now() "
        , ");"
        ]

checkFile :: Connection -> FilePath -> Checksum -> IO CheckScriptResult
checkFile con filename checksum =
    query con q (Only filename) >>= \r -> case r of
        [] ->
            return ScriptMissing
        Only actualChecksum:_ | checksum == actualChecksum ->
            return ScriptOk
        Only actualChecksum:_ ->
            return (ScriptModified actualChecksum)
    where
        q = mconcat
            [ "select checksum from schema_migrations "
            , "where filename = ? limit 1"
            ]

md5Hash :: Checksum -> Checksum
md5Hash = B64.encode . MD5.hash

type Checksum = BS.ByteString
newtype SchemaVersion = SchemaVersion String deriving (Show, Eq, Read, Ord)

data CheckScriptResult
    = ScriptOk
    | ScriptModified Checksum
    | ScriptMissing
    deriving (Show, Eq, Read, Ord)

data MigrationResult a
    = MigrationError a
    | MigrationSuccess
    deriving (Show, Eq, Read, Ord)

data MigrationContext = MigrationContext
    { migrationContextBasePath   :: FilePath
    , migrationContextVerbose    :: Bool
    , migrationContextConnection :: Connection
    }
