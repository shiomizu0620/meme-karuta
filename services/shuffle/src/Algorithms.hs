{-# LANGUAGE BangPatterns #-}

-- |
-- シャッフル系の補助アルゴリズム集。
--
-- Main.hs では Fisher-Yates を採用しているが、テストや A/B 比較のために
-- 代替アルゴリズムをいくつか実装する:
--
-- * Reservoir sampling: 大きい母集団から k 件サンプリングする
-- * Weighted shuffle: 重み付きで取り出す（カテゴリ偏りを補正する用途）
-- * Riffle shuffle: トランプ風の中央分割シャッフル
--
-- どれも純粋関数として実装し、テストしやすくしている。

module Algorithms
  ( reservoirSample
  , weightedSample
  , riffleShuffle
  , fisherYates
  , swapAt
  , chunkBy
  ) where

import           Data.List       (foldl')
import qualified Data.Vector     as V
import           Data.Vector     (Vector)
import           System.Random   (RandomGen, randomR)

-- | リザーバサンプリング。母集団のサイズが不明でも k 件等確率サンプリングできる。
reservoirSample :: RandomGen g => Int -> [a] -> g -> ([a], g)
reservoirSample k xs gen
  | k <= 0    = ([], gen)
  | otherwise =
      let (reservoir, rest, g0) = takeInitial k xs gen
      in foldStep k reservoir (zip [k..] rest) g0
  where
    takeInitial n ys g =
      let (taken, remaining) = splitAt n ys
      in (taken, remaining, g)

    foldStep _ res [] g = (res, g)
    foldStep n res ((idx, x):rest) g =
      let (j, g') = randomR (0, idx) g
      in if j < n
           then foldStep n (replaceAt j x res) rest g'
           else foldStep n res rest g'

    replaceAt :: Int -> a -> [a] -> [a]
    replaceAt _ _ [] = []
    replaceAt 0 v (_:ys) = v : ys
    replaceAt n v (y:ys) = y : replaceAt (n - 1) v ys

-- | 重み付き取り出し。weights は要素ごとの正の重み。
weightedSample :: RandomGen g => [(a, Double)] -> g -> Maybe (a, g)
weightedSample items gen
  | totalWeight <= 0 = Nothing
  | null items       = Nothing
  | otherwise =
      let (r, g') = randomR (0.0, totalWeight) gen
      in Just (pickByWeight r items, g')
  where
    totalWeight = foldl' (\acc (_, w) -> acc + max 0 w) 0 items

    pickByWeight _ []           = error "weightedSample: unreachable"
    pickByWeight _ [(x, _)]     = x
    pickByWeight remaining ((x, w):rest)
      | remaining <= w = x
      | otherwise      = pickByWeight (remaining - w) rest

-- | トランプ風の riffle シャッフル: 中央で分割し、交互に取り出す。
-- 完全なランダム性は持たないが、決定的に「混ざった感」を出すのに使う。
riffleShuffle :: [a] -> [a]
riffleShuffle xs =
  let mid           = length xs `div` 2
      (front, back) = splitAt mid xs
  in interleave front back
  where
    interleave [] ys = ys
    interleave xs [] = xs
    interleave (x:xs) (y:ys) = x : y : interleave xs ys

-- | Fisher-Yates シャッフルの Vector ベース実装（Main.hs と独立）。
fisherYates :: RandomGen g => Vector a -> g -> (Vector a, g)
fisherYates v g0 =
  let n = V.length v
  in if n <= 1 then (v, g0) else go (n - 1) v g0
  where
    go 0 vec g = (vec, g)
    go i vec g =
      let (j, g') = randomR (0, i) g
          vec'    = swapAt i j vec
      in go (i - 1) vec' g'

-- | Vector の i と j を入れ替える。
swapAt :: Int -> Int -> Vector a -> Vector a
swapAt i j v
  | i == j    = v
  | otherwise = v V.// [(i, v V.! j), (j, v V.! i)]

-- | リストを n 要素ずつのチャンクに分割する。表示用ユーティリティ。
chunkBy :: Int -> [a] -> [[a]]
chunkBy _ [] = []
chunkBy n xs
  | n <= 0    = [xs]
  | otherwise =
      let (h, t) = splitAt n xs
      in h : chunkBy n t
