{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Data.ContentStore(ContentStore,
                         contentStoreValid,
                         fetchByteString,
                         fetchLazyByteString,
                         mkContentStore,
                         openContentStore,
                         storeByteString,
                         storeLazyByteString)
 where

import           Control.Conditional((<&&>), ifM, unlessM)
import           Control.Monad(forM_)
import           Control.Monad.Except(MonadError, throwError)
import           Control.Monad.IO.Class(MonadIO, liftIO)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import           System.Directory(canonicalizePath, createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import           System.FilePath((</>))

import Data.ContentStore.Config(Config(..), defaultConfig, readConfig, writeConfig)
import Data.ContentStore.Digest(ObjectDigest(..), hashByteString, hashLazyByteString)

-- A ContentStore is its config file data and the base directory
-- where it is stored on disk.  This data type is opaque on purpose.
-- Users shouldn't concern themselves with the implementation of
-- a content store, just that it exists.
data ContentStore = ContentStore {
    csConfig :: Config,
    csRoot :: FilePath
 }

data ContentStoreError = ContentStoreInvalid String
                       | ContentStoreMissing

--
-- PRIVATE FUNCTIONS
--

-- Objects are stored in the content store in a subdirectory
-- within the objects directory.  This function makes sure that
-- path exists.
ensureObjectSubdirectory :: ContentStore -> String -> IO ()
ensureObjectSubdirectory cs subdir =
    createDirectoryIfMissing True (objectSubdirectoryPath cs subdir)

-- Assemble the directory path where an object will be stored.
objectSubdirectoryPath :: ContentStore -> String -> FilePath
objectSubdirectoryPath ContentStore{..} subdir =
    csRoot </> "objects" </> subdir

-- Where in the content store should an object be stored?  This
-- function takes the calculated digest of the object and splits
-- it into a subdirectory and the filename within that directory.
--
-- This function is used when objects are on the way into the
-- content store.
storedObjectDestination :: ObjectDigest -> (String, String)
storedObjectDestination (ObjectSHA256 digest) = splitAt 2 (show digest)
storedObjectDestination (ObjectSHA512 digest) = splitAt 2 (show digest)

-- Where in the content store is an object stored?  This function
-- takes the digest of the object that we got from somewhere outside
-- of content store code and splits it into a subdirectory and the
-- filename within that directory.
--
-- This function is used when objects are on the way out of the
-- content store.
storedObjectLocation :: String -> (String, String)
storedObjectLocation = splitAt 2

--
-- CONTENT STORE MANAGEMENT
--

-- Check that a content store exists and contains everything it's
-- supposed to.  This does not check the validity of all the contents.
-- That would be a lot of duplicated effort.
contentStoreValid :: (MonadError ContentStoreError m, MonadIO m) => FilePath -> m Bool
contentStoreValid fp = do
    unlessM (liftIO $ doesDirectoryExist fp) $
        throwError ContentStoreMissing

    unlessM (liftIO $ doesFileExist $ fp </> "config") $
        throwError $ ContentStoreInvalid "config"

    forM_ ["objects"] $ \subdir ->
        unlessM (liftIO $ doesDirectoryExist $ fp </> subdir) $
            throwError $ ContentStoreInvalid subdir

    return True

-- Create a new content store on disk, rooted at the path given.
-- Return the ContentStore record.
--
-- Lots to think about in this function.  What happens if the
-- content store already exists?  Do we just pass through to
-- openContentStore or do we fail?  What does error handling
-- look like here (and everywhere else)?  There's lots of things
-- that could go wrong creating a store on disk.  Maybe we should
-- thrown exceptions or do something besides just returning a
-- Maybe.
mkContentStore :: FilePath -> IO (Maybe ContentStore)
mkContentStore fp = do
    path <- canonicalizePath fp

    -- Create the required subdirectories.
    mapM_ (\d -> createDirectoryIfMissing True (path </> d))
          ["objects"]

    -- Write a config file.
    writeConfig (path </> "config") defaultConfig

    openContentStore path

-- Return an already existing content store.
--
-- There's a lot to think about here, too.  All the same error
-- handling questions still apply.  There should probably also
-- be a validContentStore function that checks if everything is
-- basically okay.  What happens if someone is screwing around
-- with the directory at the same time this code is running?  Do
-- we need to lock it somehow?
openContentStore :: FilePath -> IO (Maybe ContentStore)
openContentStore fp = do
    path <- canonicalizePath fp

    ifM (doesDirectoryExist path <&&> doesFileExist (path </> "config"))
        (readConfig (path </> "config") >>= \case
             Left _  -> return Nothing
             Right c -> return $ Just ContentStore { csConfig=c,
                                                     csRoot=path })
        (return Nothing)

--
-- STRICT BYTE STRING INTERFACE
--

-- Given the hash to an object in the content store, load it into
-- a ByteString.  Here, the hash is a string because it is assumed
-- it's coming from the mddb which doesn't know about various digest
-- algorithms.
fetchByteString :: ContentStore -> String -> IO (Maybe BS.ByteString)
fetchByteString cs digest = do
    let (subdir, filename) = storedObjectLocation digest
        path               = objectSubdirectoryPath cs subdir </> filename

    ifM (doesFileExist path)
        (Just <$> BS.readFile path)
        (return Nothing)

-- Given an object as a ByteString, put it into the content store.
-- Return the object's hash so it can be recorded elsewhere.
--
-- What happens if openContentStore has not been called first?
-- Is there any way of ensuring that is done?  There's also all
-- the standard IO errors that could happen here.  How do we want
-- that to be handled?
storeByteString :: ContentStore -> BS.ByteString -> IO (Maybe ObjectDigest)
storeByteString cs bs =
    case hashByteString (confHash . csConfig $ cs) bs of
        Nothing -> return Nothing
        Just digest -> do
            let (subdir, filename) = storedObjectDestination digest

            ensureObjectSubdirectory cs subdir

            -- FIXME:  What to do if the file already exists?
            BS.writeFile (objectSubdirectoryPath cs subdir </> filename)
                         bs
            return $ Just digest

--
-- LAZY BYTE STRING INTERFACE
--

-- Like fetchByteString, but uses lazy ByteStrings instead.
fetchLazyByteString :: ContentStore -> String -> IO (Maybe LBS.ByteString)
fetchLazyByteString cs digest = do
    let (subdir, filename) = storedObjectLocation digest
        path               = objectSubdirectoryPath cs subdir </> filename

    ifM (doesFileExist path)
        (Just <$> LBS.readFile path)
        (return Nothing)

-- Like storeByteString, but uses lazy ByteStrings instead.
storeLazyByteString :: ContentStore -> LBS.ByteString -> IO (Maybe ObjectDigest)
storeLazyByteString cs lbs =
    case hashLazyByteString (confHash . csConfig $ cs) lbs of
        Nothing -> return Nothing
        Just digest -> do
            let (subdir, filename) = storedObjectDestination digest

            ensureObjectSubdirectory cs subdir

            LBS.writeFile (objectSubdirectoryPath cs subdir </> filename)
                          lbs
            return $ Just digest