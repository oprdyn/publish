{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module RenderDocument
    ( program
    , initial
    )
where

import Control.Monad (filterM, when)
import Core.Program
import Core.System
import Core.Text
import Data.Char (isSpace)
import Data.List (dropWhileEnd)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import System.Directory (doesFileExist, doesDirectoryExist
    , getModificationTime, copyFileWithMetadata)
import System.FilePath.Posix (takeBaseName, takeFileName)
import System.IO (openBinaryFile, IOMode(WriteMode), hClose)
import System.IO.Error (userError, IOError)
import System.Posix.Temp (mkdtemp)
import System.Process.Typed (proc, runProcess_, setStdin, closed)
import Text.Pandoc (runIOorExplode, readMarkdown, writeLaTeX, def)

import LatexPreamble (preamble, ending)

data Env = Env
    { targetHandleFrom :: Handle
    , targetFilenameFrom :: FilePath
    , resultFilenameFrom :: FilePath
    , tempDirectoryFrom :: FilePath
    }

initial :: Env
initial = Env undefined "" "" ""

program :: Program Env ()
program = do
    bookfile <- extractBookFile

    event "Reading bookfile"
    files <- processBookFile bookfile

    event "Setup temporary directory"
    setupTargetFile bookfile

    event "Convert Markdown pieces to LaTeX"
    mapM_ processFragment files

    event "Write intermediate LaTeX file"
    produceResult

    event "Render document to PDF"
    renderPDF
    copyHere

    event "Complete"

extractBookFile :: Program Env FilePath
extractBookFile = do
    params <- getCommandLine
    case lookupArgument "bookfile" params of
        Nothing -> invalid
        Just bookfile -> return bookfile

setupTargetFile :: FilePath -> Program Env ()
setupTargetFile name = do
    tmpdir <- liftIO $ catch
        (do
            dir' <- readFile dotfile
            let dir = trim dir'
            probe <- doesDirectoryExist dir
            if probe
                then return dir
                else throw boom
        )
        (\(e :: IOError) -> do
            dir <- mkdtemp "/tmp/publish-"
            writeFile dotfile (dir ++ "\n")
            return dir
        )
    debugS "tmpdir" tmpdir

    let target = tmpdir ++ "/" ++ base ++ ".tex"
        result = tmpdir ++ "/" ++ base ++ ".pdf"

    handle <- liftIO (openBinaryFile target WriteMode)
    debugS "target" target

    liftIO $ hWrite handle preamble

    let env = Env
            { targetHandleFrom = handle
            , targetFilenameFrom = target
            , resultFilenameFrom = result
            , tempDirectoryFrom = tmpdir
            }
    setApplicationState env
  where
    dotfile = ".publish"

    base = takeBaseName name -- "/directory/file.ext" -> "file"

    boom = userError "Temp dir no longer present"

    trim :: String -> String
    trim = dropWhileEnd isSpace


processBookFile :: FilePath -> Program Env [FilePath]
processBookFile file = do
    debugS "bookfile" file
    files <- liftIO $ do
        contents <- T.readFile file
        filterM doesFileExist (possibilities contents)

    return files
  where
    -- filter out blank lines and lines commented out
    possibilities :: Text -> [FilePath]
    possibilities = map T.unpack . filter (not . T.null)
        . filter (not . T.isPrefixOf "#") . T.lines

processFragment :: FilePath -> Program Env ()
processFragment file = do
    env <- getApplicationState
    let handle = targetHandleFrom env

    debugS "fragment" file
    liftIO $ do
        contents <- T.readFile file
        latex <- runIOorExplode $ do
            parsed <- readMarkdown def contents
            writeLaTeX def parsed

        T.hPutStrLn handle latex

        -- for some reason, the Markdown -> LaTeX pair strips trailing
        -- whitespace from the block, resulting in a no paragraph boundary
        -- between files. So gratuitously add a break
        T.hPutStr handle "\n"

-- finish file
produceResult :: Program Env ()
produceResult = do
    env <- getApplicationState
    let handle = targetHandleFrom env
    liftIO $ do
        hWrite handle ending
        hClose handle


renderPDF :: Program Env ()
renderPDF = do
    env <- getApplicationState

    let target = targetFilenameFrom env
        result = resultFilenameFrom env
        tmpdir = tempDirectoryFrom env

        latexmk = proc "latexmk"

            [ "-xelatex"
            , "-output-directory=" ++ tmpdir
            , "-interaction=nonstopmode"
            , "-halt-on-error"
            , "-file-line-error"
            , target
            ]

    debugS "result" result
    liftIO $ do
        runProcess_ (setStdin closed latexmk)

copyHere :: Program Env ()
copyHere = do
    env <- getApplicationState
    let result = resultFilenameFrom env
        final = takeFileName result             -- ie ./Book.pdf
    withContext $ \runProgram -> do
        time1 <- getModificationTime result
        exists <- doesFileExist final
        time2 <- if exists
            then getModificationTime final
            else getModificationTime "/proc"    -- boot time!
        when (time1 > time2) $ do
            runProgram (debugS "final" final)
            copyFileWithMetadata result final