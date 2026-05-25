{-# LANGUAGE OverloadedStrings #-}

-- |
-- シャッフル結果の整形・表示ユーティリティ。
-- デバッグ用のテキスト出力や、JSON 文字列の組み立てを担う。

module Format
  ( formatIds
  , formatPair
  , jsonArray
  , jsonObject
  , quote
  ) where

import           Data.List (intercalate)

-- | カード ID リストを「[1, 4, 7, ...]」風に整形する。
formatIds :: [Int] -> String
formatIds xs = "[" ++ intercalate ", " (map show xs) ++ "]"

-- | (Int, Int) ペアを「1<->4」のように見せる。隣接解析の出力で使う。
formatPair :: (Int, Int) -> String
formatPair (a, b) = show a ++ "<->" ++ show b

-- | 文字列のリストを JSON 配列文字列に変換する。
jsonArray :: [String] -> String
jsonArray xs = "[" ++ intercalate ", " (map quote xs) ++ "]"

-- | (キー, 値) のペアを JSON オブジェクト文字列に変換する。
jsonObject :: [(String, String)] -> String
jsonObject kvs =
  "{" ++ intercalate ", " (map render kvs) ++ "}"
  where
    render (k, v) = quote k ++ ": " ++ v

-- | 文字列を JSON のダブルクォート文字列に整形する。
quote :: String -> String
quote s = "\"" ++ concatMap escape s ++ "\""
  where
    escape '"'  = "\\\""
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape c    = [c]
