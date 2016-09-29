{-#LANGUAGE NoImplicitPrelude #-}
{-#LANGUAGE OverloadedStrings #-}
{-#LANGUAGE OverloadedLists #-}
{-#LANGUAGE LambdaCase #-}
{-#LANGUAGE ScopedTypeVariables #-}
{-#LANGUAGE FlexibleInstances #-}
{-#LANGUAGE FlexibleContexts #-}
{-#LANGUAGE MultiParamTypeClasses #-}
module Web.Templar.Handlers.Common
where

import ClassyPrelude
import Web.Templar.Exceptions
import Web.Templar.Backends
import qualified Network.Wai as Wai
import Web.Templar.Logger as Logger
import Web.Templar.Project
import Web.Templar.ProjectConfig
import Network.HTTP.Types
       (Status, status200, status302, status400, status404, status405, status500)
import Web.Templar.Handlers.Respond
import Text.Ginger.Html (Html, htmlSource)
import Web.Templar.Backends.Loader.Type
       (PostBodySource (..), pbsFromRequest, pbsInvalid)
import Web.Templar.Rule (expandReplacementBackend)
import Data.AList (AList)
import qualified Data.AList as AList
import Text.Ginger (GVal, ToGVal (..), Run, marshalGVal)
import Control.Monad.Writer (Writer)

data NotFoundException = NotFoundException
    deriving (Show)

instance Exception NotFoundException where

data MethodNotAllowedException = MethodNotAllowedException
    deriving (Show)

instance Exception MethodNotAllowedException where

type ContextualHandler =
    HashMap Text (Items (BackendData IO Html)) -> Project -> Wai.Application

handleNotFound :: Project -> Wai.Request -> (Wai.Response -> IO Wai.ResponseReceived) -> NotFoundException -> IO Wai.ResponseReceived
handleNotFound project request respond _ = do
    handle404
        project
        request
        respond

handleMethodNotAllowed :: Project -> Wai.Request -> (Wai.Response -> IO Wai.ResponseReceived) -> MethodNotAllowedException -> IO Wai.ResponseReceived
handleMethodNotAllowed project request respond _ = do
    handle404
        project
        request
        respond

handleHttpError :: Status
                -> Text
                -> Text
                -> Project
                -> Wai.Application
handleHttpError status templateName message project request respond =
    respondNormally `catch` handleTemplateNotFound
    where
        cache = projectBackendCache project
        backendPaths = pcContextData . projectConfig $ project
        logger = projectLogger project
        respondNormally = do
            backendData <- loadBackendDict
                                (writeLog logger)
                                (pbsFromRequest request)
                                cache
                                backendPaths
                                (setFromList [])
                                (mapFromList [])
            respondTemplateHtml
                project
                status
                templateName
                backendData
                request
                respond
        handleTemplateNotFound (e :: TemplateNotFoundException) = do
            writeLog logger Logger.Warning $ "Template " ++ templateName ++ " not found, using built-in fallback"
            let headers = [("Content-type", "text/plain;charset=utf8")]
            respond . Wai.responseLBS status headers . fromStrict . encodeUtf8 $ message

handle404 :: Project
          -> Wai.Application
handle404 = handleHttpError status404 "404.html" "Not Found"

handle405 :: Project
          -> Wai.Application
handle405 = handleHttpError status405 "405.html" "Method Not Allowed"

handle500 :: SomeException
          -> Project
          -> Wai.Application
handle500 err project request respond = do
    writeLog (projectLogger project) Logger.Error $ formatException err
    handleHttpError status500 "500.html" message project request respond
    where
        message = "Something went pear-shaped. The problem seems to be on our side."

loadBackendDict :: (LogLevel -> Text -> IO ())
                -> PostBodySource
                -> RawBackendCache
                -> AList Text BackendSpec
                -> Set Text
                -> HashMap Text (GVal (Run (Writer Text) Text))
                -> IO (HashMap Text (Items (BackendData IO Html)))
loadBackendDict writeLog postBodySrc cache backendPaths required globalContext = do
    mapFromList <$> go globalContext (AList.toList backendPaths)
    where
        go :: HashMap Text (GVal (Run (Writer Text) Text))
           -> [(Text, BackendSpec)]
           -> IO [(Text, Items (BackendData IO Html))]
        go _ [] = return []
        go context ((key, backendSpec):specs) = do
            let expBackendSpec = (expandReplacementBackend context backendSpec)
            bd :: Items (BackendData IO Html)
               <- loadBackendData
                    writeLog
                    postBodySrc
                    cache
                    expBackendSpec
            resultItem <- case bd of
                NotFound ->
                    if key `elem` required
                        then throwM NotFoundException
                        else return (key, NotFound)
                _ -> return (key, bd)
            let bdG :: GVal (Run IO Html)
                bdG = toGVal bd
                bdGP :: GVal (Run (Writer Text) Text)
                bdGP = marshalGVal bdG
                context' = insertMap key bdGP context
            remainder <- go context' specs
            return $ resultItem:remainder
