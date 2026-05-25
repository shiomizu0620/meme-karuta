{-# LANGUAGE OverloadedStrings #-}

-- |
-- 入力カード ID リストのバリデーション。
--
-- gateway 経由で渡されるカード ID 配列を、シャッフル前に検査する。
-- 重複・空配列・最大件数オーバーなどを早期に検出する。

module Validate
  ( ValidationError(..)
  , validateIds
  , validateIdList
  , validateBatchSize
  , describeError
  ) where

import           Data.List       (sort)
import qualified Data.Set        as Set

-- | バリデーション失敗を表すデータ型。
data ValidationError
  = EmptyInput
  | TooManyCards Int Int       -- ^ 実数, 最大値
  | DuplicateId Int
  | InvalidId Int
  | NegativeId Int
  | BatchTooLarge Int Int      -- ^ 実数, 最大値
  deriving (Eq, Show)

-- | カード ID リスト全体を検査する。エラーは複数返ることがある。
validateIds :: [Int] -> [ValidationError]
validateIds xs =
  let lengthErr   = validateBatchSize xs
      negErrs     = [NegativeId n | n <- xs, n < 0]
      invalidErrs = [InvalidId  n | n <- xs, n == 0]
      duplicates  = findDuplicates xs
      dupErrs     = map DuplicateId duplicates
  in  lengthErr ++ negErrs ++ invalidErrs ++ dupErrs

-- | 単一カード ID の検査。0 や負数を弾く。
validateIdList :: [Int] -> Either [ValidationError] [Int]
validateIdList xs =
  case validateIds xs of
    [] -> Right xs
    es -> Left es

-- | バッチサイズだけを検査する軽量版。
validateBatchSize :: [Int] -> [ValidationError]
validateBatchSize xs
  | null xs        = [EmptyInput]
  | len > maxCards = [TooManyCards len maxCards]
  | otherwise      = []
  where
    len      = length xs
    maxCards = 256

-- | 重複している ID を列挙する。
findDuplicates :: [Int] -> [Int]
findDuplicates = go Set.empty Set.empty . sort
  where
    go _ dups []     = Set.toList dups
    go seen dups (x:rest)
      | x `Set.member` seen = go seen (Set.insert x dups) rest
      | otherwise           = go (Set.insert x seen) dups rest

-- | エラーを日本語の人間可読文字列に整形する。
describeError :: ValidationError -> String
describeError EmptyInput            = "カード ID リストが空です"
describeError (TooManyCards n m)    = "カード数が多すぎます: " ++ show n ++ " (max " ++ show m ++ ")"
describeError (DuplicateId i)       = "重複している ID: " ++ show i
describeError (InvalidId i)         = "不正な ID (0 は無効): " ++ show i
describeError (NegativeId i)        = "負の ID: " ++ show i
describeError (BatchTooLarge n m)   = "バッチが大きすぎます: " ++ show n ++ " (max " ++ show m ++ ")"
