{-# LANGUAGE BangPatterns #-}

-- |
-- シャッフル結果の品質を測る統計ユーティリティ。
--
-- 「ちゃんと混ざっているか」を数値で見るために、以下のメトリクスを提供する:
--
-- * 平均移動距離 (元の位置からどれだけずれたか)
-- * 隣接ペアの保持率 (連続するペアがどれだけ残っているか)
-- * 偏り検定: カイ二乗統計量
--
-- これらは A/B 比較やテストで「Fisher-Yates と riffle どちらが混ざるか」を
-- 評価する用途で使う。

module Stats
  ( meanDisplacement
  , adjacencyPreservation
  , chiSquare
  , Histogram
  , buildHistogram
  , histogramEntries
  , spread
  ) where

import           Data.List       (foldl', sort)
import qualified Data.Map.Strict as Map

-- | ヒストグラム本体。インデックス → 出現回数。
newtype Histogram = Histogram (Map.Map Int Int)
  deriving (Show, Eq)

-- | シャッフル前後で各要素がどれだけ動いたかの平均値。
-- 完全シャッフルなら 0.5 * n に近づく。
meanDisplacement :: (Eq a) => [a] -> [a] -> Double
meanDisplacement before after
  | length before /= length after = 0.0
  | null before                   = 0.0
  | otherwise =
      let n             = length before
          beforeIndexed = zip [0..] before
          afterIndexed  = zip [0..] after
          posMap        = Map.fromList [(x, i) | (i, x) <- afterIndexed]
          dists         = [ abs (i - Map.findWithDefault i x posMap)
                          | (i, x) <- beforeIndexed
                          ]
          total         = fromIntegral (sum dists) :: Double
      in total / fromIntegral n

-- | 元の隣接ペアがシャッフル後にも隣接して残っている割合。
-- 0.0 に近いほどよく混ざっている。
adjacencyPreservation :: (Eq a) => [a] -> [a] -> Double
adjacencyPreservation before after
  | length before < 2 = 0.0
  | otherwise =
      let beforePairs = zip before (drop 1 before)
          afterPairs  = zip after  (drop 1 after)
          preserved   = length [() | p <- beforePairs, p `elem` afterPairs]
      in fromIntegral preserved / fromIntegral (length beforePairs)

-- | カイ二乗統計量。期待度数 expected と観測度数 observed のずれを返す。
-- 値が小さいほど一様分布に近い。
chiSquare :: [Double] -> [Double] -> Double
chiSquare observed expected
  | length observed /= length expected = 0.0
  | otherwise =
      let pairs = zip observed expected
          terms = [ if e > 0 then (o - e) ** 2 / e else 0.0
                  | (o, e) <- pairs
                  ]
      in sum terms

-- | リストからヒストグラムを作る。
buildHistogram :: [Int] -> Histogram
buildHistogram = Histogram . foldl' step Map.empty
  where
    step !acc !x = Map.insertWith (+) x 1 acc

-- | ヒストグラムの (キー, 度数) のペア列。
histogramEntries :: Histogram -> [(Int, Int)]
histogramEntries (Histogram m) = Map.toAscList m

-- | リストの最大値と最小値の差。データの散らばり指標。
spread :: (Ord a, Num a) => [a] -> a
spread [] = 0
spread xs = maximum xs - minimum xs

-- | 中央値。偶数個の場合は中央 2 値の平均。
median :: (Ord a, Fractional a) => [a] -> a
median [] = 0
median xs =
  let sorted = sort xs
      n      = length sorted
      mid    = n `div` 2
  in  if even n
        then (sorted !! (mid - 1) + sorted !! mid) / 2
        else sorted !! mid

-- | 平均値。
average :: (Fractional a) => [a] -> a
average [] = 0
average xs = sum xs / fromIntegral (length xs)
