-- | 軽量ロガー (stdout のみ)。
module Logger
  ( LogLevel(..)
  , formatLine
  ) where

data LogLevel = Info | Warn | Error
  deriving (Eq, Show)

formatLine :: String -> LogLevel -> String -> String
formatLine ts lvl msg = ts ++ " [" ++ tag lvl ++ "] " ++ msg
  where
    tag Info  = "INFO"
    tag Warn  = "WARN"
    tag Error = "ERROR"
