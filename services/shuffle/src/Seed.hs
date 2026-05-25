{-# LANGUAGE BangPatterns #-}

-- |
-- シード生成・管理ユーティリティ。
--
-- シャッフル結果の再現性を担保するために、ルーム ID と開始時刻から
-- 決定的にシードを作る。テストでは同じシードを与えれば同じ結果が出る。
--
-- - 暗号学的に強い必要は無いが、衝突しにくいハッシュを使う (FNV-1a)
-- - 文字列以外の情報 (タイムスタンプ、ユーザ ID) も混ぜられるように
--   `mixSeed` で合成可能にする

module Seed
  ( seedFromRoomId
  , seedFromBytes
  , mixSeed
  , chunkedSeed
  , describeSeed
  ) where

import           Data.Bits   (shiftL, xor, (.&.))
import           Data.Char   (ord)
import           Data.Word   (Word32, Word64)

-- | FNV-1a の 32bit オフセット。
fnvOffset :: Word32
fnvOffset = 0x811C9DC5

-- | FNV-1a の 32bit prime。
fnvPrime :: Word32
fnvPrime = 0x01000193

-- | 文字列を 32bit シードに変換する。
seedFromRoomId :: String -> Word32
seedFromRoomId = seedFromBytes . map (fromIntegral . ord)

-- | バイト列から 32bit シードを作る。
seedFromBytes :: [Word32] -> Word32
seedFromBytes = foldl step fnvOffset
  where
    step !acc !b =
      let xored = acc `xor` (b .&. 0xFF)
      in  xored * fnvPrime

-- | 2 つのシードを混ぜて新しいシードを作る。
-- ルーム ID とタイムスタンプを合成する用途。
mixSeed :: Word32 -> Word32 -> Word32
mixSeed a b =
  let !x = (a `xor` (b * 0x85EBCA6B))
      !y = x `xor` (x `shiftL` 13)
  in  y * fnvPrime

-- | シードを使い切らないようにシャッフルごとに分割する。
-- 同じ初期シードから N 個のサブシードを派生させる。
chunkedSeed :: Word32 -> Int -> [Word32]
chunkedSeed _    n | n <= 0 = []
chunkedSeed base n = take n (iterate stir base)
  where
    stir s = mixSeed s 0x9E3779B9

-- | シードの 16 進表記を返す（ログ・デバッグ用）。
describeSeed :: Word32 -> String
describeSeed w = "0x" ++ pad 8 (toHex w)
  where
    pad k s = replicate (k - length s) '0' ++ s

    toHex 0 = "0"
    toHex x = reverse (go x)
      where
        go 0  = ""
        go !n =
          let !d = n .&. 0xF
              !c = digitChar (fromIntegral d :: Int)
          in c : go (n `div` 16)

    digitChar n
      | n < 10    = toEnum (fromEnum '0' + n)
      | otherwise = toEnum (fromEnum 'a' + n - 10)

-- | 64bit シードが必要な場面用に、2 つの 32bit シードを結合する。
joinSeed64 :: Word32 -> Word32 -> Word64
joinSeed64 hi lo =
  (fromIntegral hi `shiftL` 32) + fromIntegral lo
