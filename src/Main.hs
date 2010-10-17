module Main where

import Control.Applicative
    ( (<*>)
    , pure
    )
import Control.Monad
    ( when
    , forM_
    )
import Control.Concurrent
    ( threadDelay
    )
import System.IO
    ( IOMode(WriteMode)
    , Handle
    , openFile
    , hPutStr
    , hClose
    )
import System.Exit
    ( exitFailure
    )
import System.Environment
    ( getEnvironment
    , getArgs
    )
import System.Directory
    ( doesDirectoryExist
    , doesFileExist
    , removeFile
    , copyFile
    , createDirectory
    )
import System.FilePath
    ( (</>)
    )
import System.Posix.Files
    ( getFileStatus
    , modificationTime
    , createSymbolicLink
    )
import Data.Maybe
    ( isNothing
    )
import Data.Time.LocalTime
    ( TimeZone(timeZoneName)
    , getCurrentTimeZone
    )
import Data.Time.Clock
    ( getCurrentTime
    )
import qualified Text.Pandoc as Pandoc
import MB.Templates
    ( loadTemplate
    , renderTemplate
    )
import MB.Processing
    ( processPost
    )
import MB.Util
    ( copyTree
    , toUtcTime
    , toLocalTime
    , rssModificationTime
    , loadPostIndex
    , savePostIndex
    , getModificationTime
    , allPostFilenames
    )
import MB.Gladtex
    ( gladTex
    , checkForGladtex
    )
import MB.Types
import qualified MB.Files as Files
import Paths_mathblog
    ( getDataFileName
    )

skelDir :: IO FilePath
skelDir = getDataFileName "skel"

baseDirEnvName :: String
baseDirEnvName = "MB_BASE_DIR"

baseUrlEnvName :: String
baseUrlEnvName = "MB_BASE_URL"

commonTemplateAttrs :: Config -> [(String, String)]
commonTemplateAttrs config = [ ("baseUrl", baseUrl config )
                             ]

writeTemplate :: Config -> Handle -> Template -> [(String, String)] -> IO ()
writeTemplate config h t attrs = do
  let out = renderTemplate attrs' t
      attrs' = commonTemplateAttrs config ++ attrs
  hPutStr h out

allPosts :: Config -> IO [Post]
allPosts config = do
  -- Load the post index
  postIndex <- loadPostIndex config

  -- Save the post index
  savePostIndex config postIndex

  -- Return posts sorted by the index
  let PostIndex posts = postIndex
  return posts

pandocWriterOptions :: Pandoc.WriterOptions
pandocWriterOptions =
    Pandoc.defaultWriterOptions { Pandoc.writerHTMLMathMethod = Pandoc.GladTeX
                                }

writePost :: Handle -> Post -> IO ()
writePost h post = do
  created <- postModificationString post
  hPutStr h $ "<h1>" ++ postTitle post 175 ++ "</h1>"
  hPutStr h $ "<span class=\"post-created\">Posted " ++ created ++ "</span>"
  hPutStr h $ Pandoc.writeHtmlString pandocWriterOptions (postAst post)

buildLinks :: Config -> Maybe Post -> Maybe Post -> String
buildLinks config prev next =
    "<div id=\"prev-next-links\">"
      ++ link "next-link" "older" next
      ++ link "prev-link" "newer" prev
      ++ "</div>"
        where
          link cls name Nothing =
              "<span class=\"" ++ cls ++ "-subdued\">" ++ name ++ "</span>"
          link cls name (Just p) =
              "<a class=\"" ++ cls ++ "\" href=\"" ++ Files.postUrl config p ++
                                "\">" ++ name ++ "</a>"

jsInfo :: Post -> String
jsInfo post =
    "<script type=\"text/javascript\">\n" ++
    "Blog = {\n" ++
    "  pageName: " ++ show (Files.postBaseName post) ++
    "\n" ++
    "};\n" ++
    "</script>\n"

buildPost :: Handle -> Config -> Post -> (Maybe Post, Maybe Post) -> IO ()
buildPost h config post prevNext = do
  hPutStr h =<< (readFile $ Files.pagePreamble config)
  hPutStr h $ jsInfo post
  hPutStr h $ uncurry (buildLinks config) prevNext
  hPutStr h =<< (readFile $ Files.postPreamble config)
  hPutStr h =<< (readFile $ Files.postIntermediateHtml config post)
  hPutStr h =<< (readFile $ Files.postPostamble config)
  hPutStr h =<< (readFile $ Files.pagePostamble config)

generatePost :: Config -> Post -> IO ()
generatePost config post = do
  let tempHtml = htmlTempDir config </> Files.postBaseName post ++ ".html"
      finalHtml = Files.postIntermediateHtml config post

  htmlExists <- doesFileExist finalHtml
  skip <- case htmlExists of
            False -> return False
            True -> do
              info <- getFileStatus finalHtml
              return $ (toUtcTime $ modificationTime info) > postModificationTime post

  when (not skip) $ do
    putStrLn $ "Processing: " ++ Files.postBaseName post

    h <- openFile (Files.postHtex config post) WriteMode
    writePost h =<< processPost config post
    hClose h

    -- Run gladtex on the temp file to generate the final file.
    gladTex config (Files.postHtex config post) "000000"

    -- Gladtex generates the HTML in the same directory as the source
    -- file, so we need to copy that to the final location.
    copyFile tempHtml finalHtml

    -- Remove the temporary file.
    removeFile $ Files.postHtex config post
    removeFile tempHtml

generatePosts :: Config -> [Post] -> IO ()
generatePosts config posts = do
  let n = length posts
  forM_ (zip posts [0..]) $ \(p, i) ->
      do
        let prevPost = if i == 0 then Nothing else Just (posts !! (i - 1))
            nextPost = if i == n - 1 then Nothing else Just (posts !! (i + 1))

        generatePost config p
        h <- openFile (Files.postFinalHtml config p) WriteMode
        buildPost h config p (prevPost, nextPost)
        hClose h

generateIndex :: Config -> Post -> IO ()
generateIndex config post = do
  let dest = Files.postFinalHtml config post
      index = Files.indexHtml config

  exists <- doesFileExist index
  when exists $ removeFile index

  createSymbolicLink dest index

postModificationString :: Post -> IO String
postModificationString p = do
  tz <- getCurrentTimeZone
  localTime <- toLocalTime $ postModificationTime p
  return $ show localTime ++ "  " ++ timeZoneName tz

generateList :: Config -> [Post] -> IO ()
generateList config posts = do
  putStrLn "Generating all-posts list."

  h <- openFile (Files.listHtex config) WriteMode

  hPutStr h =<< (readFile $ Files.pagePreamble config)
  hPutStr h "<div id=\"all-posts\">"

  -- For each post in the order they were given, extract the
  -- unrendered title and construct an htex document.  Then render it
  -- to the listing location.
  forM_ posts $ \p -> do
    created <- postModificationString p
    hPutStr h $ concat [ "<div class=\"listing-entry\"><span class=\"post-title\">"
                       , "<a href=\"" ++ Files.postUrl config p ++ "\">"
                       , postTitle p 110
                       , "</a></span><span class=\"post-created\">Posted "
                       , created
                       , "</span></div>\n"
                       ]

  hPutStr h "</div>"
  hPutStr h =<< (readFile $ Files.pagePostamble config)
  hClose h

  gladTex config (Files.listHtex config) "0000FF"

  -- Gladtex generates the HTML in the same directory as the source
  -- file, so we need to copy that to the final location.
  copyFile (Files.listTmpHtml config) (Files.listHtml config)

  -- Remove the temporary file.
  removeFile $ Files.listHtex config
  removeFile $ Files.listTmpHtml config

rssItem :: Config -> Post -> String
rssItem config p =
    concat [ "<item>"
           , "<title>" ++ postTitleRaw p ++ "</title>\n"
           , "<link>" ++ Files.postUrl config p ++ "</link>\n"
           , "<pubDate>" ++ rssModificationTime p ++ "</pubDate>\n"
           , "<guid>" ++ Files.postUrl config p ++ "</guid>\n"
           , "</item>\n"
           ]

generateRssFeed :: Config -> [Post] -> IO ()
generateRssFeed config posts = do
  h <- openFile (Files.rssXml config) WriteMode

  eTmpl <- loadTemplate $ Files.rssTemplatePath config

  case eTmpl of
    Left msg -> putStrLn msg >> exitFailure
    Right tmpl ->
        do
          let items = map (rssItem config) posts
              itemStr = concat items
              attrs = [ ("items", itemStr)
                      ]

          writeTemplate config h tmpl attrs
          hClose h

setup :: Config -> IO ()
setup config = do
  exists <- doesDirectoryExist $ baseDir config
  dataDir <- skelDir

  when (not exists) $ do
          putStrLn $ "Setting up data directory using skeleton: " ++ dataDir
          copyTree dataDir $ baseDir config

  ensureDirs config

ensureDirs :: Config -> IO ()
ensureDirs config = do
  let dirs = [ postSourceDir
             , htmlDir
             , stylesheetDir
             , postHtmlDir
             , postIntermediateDir
             , imageDir
             , templateDir
             , htmlTempDir
             , eqPreamblesDir
             ]

  forM_ (dirs <*> pure config) $ \d ->
      do
        exists <- doesDirectoryExist d
        when (not exists) $ createDirectory d

-- The files we look at to decide whether to regenerate the blog.
-- We'll always look at the post input files, but we also want to look
-- at other files to trigger a regeneration.
changedFiles :: Config -> [FilePath]
changedFiles config = [ Files.rssTemplatePath
                      , Files.pagePreamble
                      , Files.pagePostamble
                      , Files.postPreamble
                      , Files.postPostamble
                      ] <*> pure config

preserveM :: (Monad m) => (a -> m b) -> a -> m (a, b)
preserveM act val = act val >>= \r -> return (val, r)

scanForChanges :: Config -> IO () -> IO ()
scanForChanges config act = do
  t <- getCurrentTime
  scan t
      where
        scan t = do
          posts <- allPostFilenames config
          let filesToInspect = posts ++ changedFiles config
          allTimes <- mapM (preserveM getModificationTime) filesToInspect

          let modified = filter ((> t) . snd) allTimes
              nextTime = if null modified
                         then t
                         else maximum $ map snd modified

          when (not $ null modified) $
               do
                 putStrLn ""
                 putStrLn "Changes detected:"
                 forM_ modified $ \(fp, _) -> do
                              putStrLn $ "  " ++ fp
                 act
          threadDelay $ 1 * 1000 * 1000
          scan nextTime

mkConfig :: FilePath -> String -> Config
mkConfig base url = Config { baseDir = base
                           , postSourceDir = base </> "posts"
                           , htmlDir = base </> "html"
                           , stylesheetDir = base </> "html" </> "stylesheets"
                           , postHtmlDir = base </> "html" </> "posts"
                           , postIntermediateDir = base </> "generated"
                           , imageDir = base </> "html" </> "generated-images"
                           , templateDir = base </> "templates"
                           , htmlTempDir = base </> "tmp"
                           , baseUrl = url
                           , eqPreamblesDir = base </> "eq-preambles"
                           }

usage :: IO ()
usage = do
  putStrLn "Usage: mb [-l]\n"
  putStrLn "mb is a tool for creating and managing a mathematically-inclined"
  putStrLn "weblog.  To use mb, you must set a few environment variables:"
  putStrLn ""
  putStrLn $ "  " ++ baseDirEnvName ++ ": path where blog files will be stored"
  putStrLn $ "  " ++ baseUrlEnvName ++ ": base URL where blog will be hosted"
  putStrLn ""
  putStrLn " -l: make mb poll periodically and regenerate your blog content"
  putStrLn "     when something changes.  This is useful if you want to run a"
  putStrLn "     local web server to view your posts as you're writing them."

main :: IO ()
main = do
  env <- getEnvironment
  args <- getArgs

  checkForGladtex

  let mBase = lookup baseDirEnvName env
      mBaseUrl = lookup baseUrlEnvName env

  when (isNothing (mBase >> mBaseUrl)) $ usage >> exitFailure

  let Just dir = mBase
      Just url = mBaseUrl

  when (head dir /= '/') $ do
         putStrLn $ baseDirEnvName ++ " must contain an absolute path"
         exitFailure

  putStrLn $ "mb: using base directory " ++ (show dir)
  putStrLn $ "mb: using base url " ++ (show url)
  let config = mkConfig dir url
  setup config

  let work = do
         posts <- allPosts config
         generatePosts config posts
         generateIndex config $ head posts
         generateList config posts
         generateRssFeed config posts
         putStrLn "Done."

  case args of
    [] -> work
    ["-l"] -> work >> scanForChanges config work
    _ -> usage >> exitFailure