module MB.Config
    ( readConfig
    , affirmative
    )
where

import Control.Applicative
import Data.Char (toLower)
import Data.ConfigFile.Parser
    ( parse_file
    )
import System.Exit
    ( exitFailure
    )
import Data.Maybe
    ( fromJust
    , isNothing
    )
import Control.Monad
    ( forM_
    , when
    )

section :: String
section = "DEFAULT"

readConfig :: FilePath -> [String] -> IO [(String, String)]
readConfig path requiredArgs = do
  result <- parse_file path

  case result of
    Left e ->
        do
          putStrLn $ "Error parsing config file " ++ path ++ ": " ++ show e
          exitFailure
    Right cfg ->
        do
          let pairs = fromJust $ lookup section cfg

          forM_ requiredArgs $ \k ->
            when (isNothing $ lookup k pairs) $
                 do
                   putStrLn $ "Missing required value for '" ++ k ++ "' in " ++ path
                   exitFailure

          return pairs

affirmative :: String -> Bool
affirmative s = aff $ toLower <$> s
    where
      aff "yes" = True
      aff "on" = True
      aff "1" = True
      aff _ = False