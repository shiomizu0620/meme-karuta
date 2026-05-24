{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, replicateM, when)
import Data.Aeson (FromJSON, ToJSON, decode, encode, object, parseJSON, withObject, (.=), (.:))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (group, nub, sort)
import Data.Maybe (fromMaybe)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV
import Network.HTTP.Types
  ( Status, hContentType, methodGet, methodOptions, methodPost
  , status200, status400, status404, status405, status500
  )
import Network.Wai (Request, Response, lazyRequestBody, rawPathInfo, requestMethod, responseLBS)
import Network.Wai.Handler.Warp (run)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import System.Random (RandomGen, mkStdGen, randomR, randomRIO, newStdGen)

-- ---- 型定義 ----

newtype ShuffleRequest = ShuffleRequest { unIds :: [Int] }

data ShuffleResult = ShuffleResult
  { srIds       :: [Int]
  , srAlgorithm :: String
  , srCount     :: Int
  }

data ShuffleError
  = InvalidInput String
  | TooManyItems Int Int
  | EmptyInput
  deriving (Show)

data ShuffleStats = ShuffleStats
  { ssCount     :: Int
  , ssMin       :: Int
  , ssMax       :: Int
  , ssUnique    :: Int
  , ssEntropy   :: Double
  }

maxShuffleSize :: Int
maxShuffleSize = 10000

-- ---- Fisher-Yates シャッフル（乱数ソース: IO） ----

fisherYates :: V.Vector Int -> IO (V.Vector Int)
fisherYates vec = do
  mv <- V.thaw vec
  let n = MV.length mv
  forM_ [n - 1, n - 2 .. 1] $ \i -> do
    j <- randomRIO (0, i)
    MV.swap mv i j
  V.freeze mv

-- ---- Sattolo サイクル（閉路のないランダム置換） ----

sattoloShuffle :: V.Vector Int -> IO (V.Vector Int)
sattoloShuffle vec = do
  mv <- V.thaw vec
  let n = MV.length mv
  forM_ [n - 1, n - 2 .. 1] $ \i -> do
    j <- randomRIO (0, i - 1)
    MV.swap mv i j
  V.freeze mv

-- ---- シード付き再現可能シャッフル ----

fisherYatesWithSeed :: Int -> V.Vector Int -> V.Vector Int
fisherYatesWithSeed seed vec = V.create $ do
  mv <- V.thaw vec
  let n   = MV.length mv
      gen = mkStdGen seed
  let go _ 0 = return ()
      go g i = do
        let (j, g') = randomR (0, i) g
        MV.swap mv i j
        go g' (i - 1)
  go gen (n - 1)
  return mv

-- ---- バリデーション ----

validateInput :: [Int] -> Either ShuffleError (V.Vector Int)
validateInput [] = Left EmptyInput
validateInput ids
  | length ids > maxShuffleSize =
      Left (TooManyItems (length ids) maxShuffleSize)
  | otherwise = Right (V.fromList ids)

-- ---- 統計計算 ----

computeStats :: V.Vector Int -> ShuffleStats
computeStats vec =
  let lst    = V.toList vec
      n      = length lst
      mn     = minimum lst
      mx     = maximum lst
      uniq   = length (nub lst)
      counts = map length . group . sort $ lst
      probs  = map (\c -> fromIntegral c / fromIntegral n :: Double) counts
      ent    = negate . sum . map (\p -> if p > 0 then p * logBase 2 p else 0) $ probs
  in ShuffleStats
      { ssCount   = n
      , ssMin     = mn
      , ssMax     = mx
      , ssUnique  = uniq
      , ssEntropy = ent
      }

-- ---- JSON レスポンス ----

jsonResponse :: (ToJSON a) => Status -> a -> Response
jsonResponse status body =
  responseLBS status
    [ (hContentType, "application/json; charset=utf-8")
    , ("Access-Control-Allow-Origin",  "*")
    , ("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    , ("Access-Control-Allow-Headers", "Content-Type")
    ]
    (encode body)

corsPreflightResponse :: Response
corsPreflightResponse =
  responseLBS status200
    [ ("Access-Control-Allow-Origin",  "*")
    , ("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    , ("Access-Control-Allow-Headers", "Content-Type")
    ]
    LBS.empty

errorResponse :: Status -> String -> Response
errorResponse s msg = jsonResponse s (object ["error" .= msg])

-- ---- リクエストハンドラ ----

handleRequest :: Request -> IO Response
handleRequest req =
  case (requestMethod req, rawPathInfo req) of

    (m, _) | m == methodOptions ->
      return corsPreflightResponse

    (m, "/health") | m == methodGet ->
      return $ jsonResponse status200 (object
        [ "status"           .= ("ok" :: String)
        , "max_shuffle_size" .= maxShuffleSize
        ])

    (m, "/metrics") | m == methodGet ->
      handleMetrics

    (m, "/distribution") | m == methodPost ->
      handleDistribution req

    (m, "/partition") | m == methodPost ->
      handlePartition req

    (m, "/sample") | m == methodPost ->
      handleSample req

    (m, "/shuffle") | m == methodPost ->
      handleShuffle req

    (m, "/shuffle/sattolo") | m == methodPost ->
      handleSattoloShuffle req

    (m, "/shuffle/seed") | m == methodPost ->
      handleSeededShuffle req

    (m, "/shuffle/n") | m == methodPost ->
      handleShuffleN req

    (m, "/stats") | m == methodPost ->
      handleStats req

    (m, "/verify") | m == methodPost ->
      handleVerify req

    (m, "/shuffle/weighted") | m == methodPost ->
      handleWeighted req

    (m, "/benchmark") | m == methodPost ->
      handleBenchmark req

    (m, "/shuffle/repeat") | m == methodPost ->
      handleRepeat req

    (_, "/shuffle")          -> return $ errorResponse status405 "POST required"
    (_, "/shuffle/sattolo")  -> return $ errorResponse status405 "POST required"
    (_, "/shuffle/seed")     -> return $ errorResponse status405 "POST required"
    (_, "/shuffle/weighted") -> return $ errorResponse status405 "POST required"
    (_, "/shuffle/repeat")   -> return $ errorResponse status405 "POST required"
    (_, "/stats")            -> return $ errorResponse status405 "POST required"
    (_, "/verify")           -> return $ errorResponse status405 "POST required"
    (_, "/benchmark")        -> return $ errorResponse status405 "POST required"
    _                        -> return $ errorResponse status404 "not found"

-- ---- /shuffle: 標準 Fisher-Yates ----

handleShuffle :: Request -> IO Response
handleShuffle req = do
  body <- lazyRequestBody req
  case decode body :: Maybe [Int] of
    Nothing  -> return $ errorResponse status400 "expected JSON array of integers"
    Just ids -> case validateInput ids of
      Left EmptyInput          -> return $ errorResponse status400 "empty array"
      Left (TooManyItems n mx) -> return $ errorResponse status400
        ("too many items: " ++ show n ++ " (max " ++ show mx ++ ")")
      Left (InvalidInput msg)  -> return $ errorResponse status400 msg
      Right vec -> do
        shuffled <- fisherYates vec
        return $ jsonResponse status200 (V.toList shuffled)

-- ---- /shuffle/sattolo: Sattolo サイクル ----

handleSattoloShuffle :: Request -> IO Response
handleSattoloShuffle req = do
  body <- lazyRequestBody req
  case decode body :: Maybe [Int] of
    Nothing  -> return $ errorResponse status400 "expected JSON array of integers"
    Just ids -> case validateInput ids of
      Left EmptyInput -> return $ errorResponse status400 "empty array"
      Left (TooManyItems n mx) -> return $ errorResponse status400
        ("too many items: " ++ show n ++ " (max " ++ show mx ++ ")")
      Left (InvalidInput msg) -> return $ errorResponse status400 msg
      Right vec
        | V.length vec < 2 -> return $ jsonResponse status200 ids
        | otherwise -> do
            shuffled <- sattoloShuffle vec
            return $ jsonResponse status200
              (object ["ids" .= V.toList shuffled, "algorithm" .= ("sattolo" :: String)])

-- ---- /shuffle/seed: シード付き再現可能シャッフル ----

data SeededRequest = SeededRequest
  { srIds2 :: [Int]
  , srSeed :: Int
  }

instance Data.Aeson.FromJSON SeededRequest where
  parseJSON = Data.Aeson.withObject "SeededRequest" $ \v ->
    SeededRequest <$> v Data.Aeson..: "ids" <*> v Data.Aeson..: "seed"

handleSeededShuffle :: Request -> IO Response
handleSeededShuffle req = do
  body <- lazyRequestBody req
  case Data.Aeson.decode body :: Maybe SeededRequest of
    Nothing -> return $ errorResponse status400 "expected {\"ids\":[...],\"seed\":N}"
    Just sr -> case validateInput (srIds2 sr) of
      Left EmptyInput -> return $ errorResponse status400 "empty ids array"
      Left (TooManyItems n mx) -> return $ errorResponse status400
        ("too many items: " ++ show n ++ " (max " ++ show mx ++ ")")
      Left (InvalidInput msg) -> return $ errorResponse status400 msg
      Right vec -> do
        let shuffled = fisherYatesWithSeed (srSeed sr) vec
        return $ jsonResponse status200
          (object
            [ "ids"       .= V.toList shuffled
            , "seed"      .= srSeed sr
            , "algorithm" .= ("fisher-yates-seeded" :: String)
            ])

-- ---- /shuffle/n: 先頭 N 枚だけシャッフルして返す ----

data ShuffleNRequest = ShuffleNRequest
  { snIds :: [Int]
  , snN   :: Int
  }

instance Data.Aeson.FromJSON ShuffleNRequest where
  parseJSON = Data.Aeson.withObject "ShuffleNRequest" $ \v ->
    ShuffleNRequest <$> v Data.Aeson..: "ids" <*> v Data.Aeson..: "n"

handleShuffleN :: Request -> IO Response
handleShuffleN req = do
  body <- lazyRequestBody req
  case Data.Aeson.decode body :: Maybe ShuffleNRequest of
    Nothing -> return $ errorResponse status400 "expected {\"ids\":[...],\"n\":N}"
    Just sr
      | snN sr < 1 -> return $ errorResponse status400 "n must be >= 1"
      | snN sr > length (snIds sr) ->
          return $ errorResponse status400 "n exceeds ids length"
      | otherwise -> case validateInput (snIds sr) of
          Left err -> case err of
            EmptyInput -> return $ errorResponse status400 "empty ids"
            TooManyItems n mx -> return $ errorResponse status400
              ("too many items: " ++ show n ++ " (max " ++ show mx ++ ")")
            InvalidInput msg -> return $ errorResponse status400 msg
          Right vec -> do
            shuffled <- fisherYates vec
            let taken = V.toList (V.take (snN sr) shuffled)
            return $ jsonResponse status200
              (object ["ids" .= taken, "n" .= snN sr, "total" .= V.length vec])

-- ---- /stats: シャッフル後の統計情報 ----

handleStats :: Request -> IO Response
handleStats req = do
  body <- lazyRequestBody req
  case decode body :: Maybe [Int] of
    Nothing  -> return $ errorResponse status400 "expected JSON array of integers"
    Just ids -> case validateInput ids of
      Left EmptyInput -> return $ errorResponse status400 "empty array"
      Left (TooManyItems n mx) -> return $ errorResponse status400
        ("too many items: " ++ show n ++ " (max " ++ show mx ++ ")")
      Left (InvalidInput msg) -> return $ errorResponse status400 msg
      Right vec -> do
        shuffled <- fisherYates vec
        let stats = computeStats shuffled
        return $ jsonResponse status200
          (object
            [ "shuffled" .= V.toList shuffled
            , "stats" .= object
                [ "count"   .= ssCount stats
                , "min"     .= ssMin stats
                , "max"     .= ssMax stats
                , "unique"  .= ssUnique stats
                , "entropy" .= ssEntropy stats
                ]
            ])

-- ---- /verify: 順列の妥当性検証 ----

data VerifyRequest = VerifyRequest
  { vrOriginal :: [Int]
  , vrShuffled :: [Int]
  }

instance Data.Aeson.FromJSON VerifyRequest where
  parseJSON = Data.Aeson.withObject "VerifyRequest" $ \v ->
    VerifyRequest <$> v Data.Aeson..: "original" <*> v Data.Aeson..: "shuffled"

isValidPermutation :: [Int] -> [Int] -> (Bool, [String])
isValidPermutation orig shuf =
  let errors =
        [ "length mismatch: " ++ show (length orig) ++ " vs " ++ show (length shuf)
        | length orig /= length shuf
        ]
        ++
        [ "element set differs"
        | sort orig /= sort shuf
        ]
        ++
        [ "duplicates in shuffled output"
        | length (nub shuf) /= length shuf
        ]
  in (null errors, errors)

handleVerify :: Request -> IO Response
handleVerify req = do
  body <- lazyRequestBody req
  case Data.Aeson.decode body :: Maybe VerifyRequest of
    Nothing -> return $ errorResponse status400 "expected {\"original\":[...],\"shuffled\":[...]}"
    Just vr -> do
      let (ok, errs) = isValidPermutation (vrOriginal vr) (vrShuffled vr)
          identical = vrOriginal vr == vrShuffled vr
      return $ jsonResponse status200 (object
        [ "valid"      .= ok
        , "identical"  .= identical
        , "errors"     .= errs
        , "size"       .= length (vrOriginal vr)
        ])

-- ---- /shuffle/weighted: 重み付きシャッフル ----

data WeightedRequest = WeightedRequest
  { wrIds     :: [Int]
  , wrWeights :: [Double]
  }

instance Data.Aeson.FromJSON WeightedRequest where
  parseJSON = Data.Aeson.withObject "WeightedRequest" $ \v ->
    WeightedRequest <$> v Data.Aeson..: "ids" <*> v Data.Aeson..: "weights"

weightedSample :: [Int] -> [Double] -> IO [Int]
weightedSample ids ws = go (zip ids ws)
  where
    go []   = return []
    go pool = do
      let total = sum (map snd pool)
      if total <= 0 then return (map fst pool)
      else do
        r <- randomRIO (0, total)
        let (picked, rest) = pickByWeight r pool
        more <- go rest
        return (picked : more)

    pickByWeight :: Double -> [(Int, Double)] -> (Int, [(Int, Double)])
    pickByWeight _ [] = error "empty pool"
    pickByWeight r ((x, w):xs)
      | r <= w    = (x, xs)
      | otherwise = let (y, ys) = pickByWeight (r - w) xs in (y, (x, w) : ys)

handleWeighted :: Request -> IO Response
handleWeighted req = do
  body <- lazyRequestBody req
  case Data.Aeson.decode body :: Maybe WeightedRequest of
    Nothing -> return $ errorResponse status400 "expected {\"ids\":[...],\"weights\":[...]}"
    Just wr
      | length (wrIds wr) /= length (wrWeights wr) ->
          return $ errorResponse status400 "ids and weights length mismatch"
      | any (< 0) (wrWeights wr) ->
          return $ errorResponse status400 "weights must be non-negative"
      | length (wrIds wr) > maxShuffleSize ->
          return $ errorResponse status400
            ("too many items: max " ++ show maxShuffleSize)
      | null (wrIds wr) ->
          return $ errorResponse status400 "empty ids"
      | otherwise -> do
          picked <- weightedSample (wrIds wr) (wrWeights wr)
          return $ jsonResponse status200 (object
            [ "ids"       .= picked
            , "algorithm" .= ("weighted-sample" :: String)
            ])

-- ---- /benchmark: 複数試行のエントロピー分散 ----

data BenchmarkRequest = BenchmarkRequest
  { brIds        :: [Int]
  , brIterations :: Int
  }

instance Data.Aeson.FromJSON BenchmarkRequest where
  parseJSON = Data.Aeson.withObject "BenchmarkRequest" $ \v ->
    BenchmarkRequest <$> v Data.Aeson..: "ids" <*> v Data.Aeson..: "iterations"

handleBenchmark :: Request -> IO Response
handleBenchmark req = do
  body <- lazyRequestBody req
  case Data.Aeson.decode body :: Maybe BenchmarkRequest of
    Nothing -> return $ errorResponse status400
      "expected {\"ids\":[...],\"iterations\":N}"
    Just br
      | brIterations br < 1 || brIterations br > 1000 ->
          return $ errorResponse status400 "iterations must be in [1,1000]"
      | otherwise -> case validateInput (brIds br) of
          Left EmptyInput -> return $ errorResponse status400 "empty ids"
          Left (TooManyItems n mx) -> return $ errorResponse status400
            ("too many items: " ++ show n ++ " (max " ++ show mx ++ ")")
          Left (InvalidInput msg) -> return $ errorResponse status400 msg
          Right vec -> do
            entropies <- replicateM (brIterations br) $ do
              shuffled <- fisherYates vec
              return (ssEntropy (computeStats shuffled))
            let n      = length entropies
                avg    = sum entropies / fromIntegral n
                vari   = sum (map (\e -> (e - avg) ** 2) entropies) / fromIntegral n
                stdDev = sqrt vari
                mnE    = minimum entropies
                mxE    = maximum entropies
            return $ jsonResponse status200 (object
              [ "iterations" .= n
              , "size"       .= V.length vec
              , "mean"       .= avg
              , "stddev"     .= stdDev
              , "min"        .= mnE
              , "max"        .= mxE
              ])

-- ---- /shuffle/repeat: 同じ入力に対し N 回シャッフルを返す ----

handleRepeat :: Request -> IO Response
handleRepeat req = do
  body <- lazyRequestBody req
  case Data.Aeson.decode body :: Maybe ShuffleNRequest of
    Nothing -> return $ errorResponse status400 "expected {\"ids\":[...],\"n\":N}"
    Just sr
      | snN sr < 1 || snN sr > 100 ->
          return $ errorResponse status400 "n must be in [1,100]"
      | otherwise -> case validateInput (snIds sr) of
          Left EmptyInput -> return $ errorResponse status400 "empty ids"
          Left (TooManyItems n mx) -> return $ errorResponse status400
            ("too many items: " ++ show n ++ " (max " ++ show mx ++ ")")
          Left (InvalidInput msg) -> return $ errorResponse status400 msg
          Right vec -> do
            runs <- replicateM (snN sr) (V.toList <$> fisherYates vec)
            let collisions = computeCollisions runs
            return $ jsonResponse status200 (object
              [ "runs"       .= runs
              , "iterations" .= snN sr
              , "collisions" .= collisions
              ])

computeCollisions :: [[Int]] -> Int
computeCollisions runs =
  let pairs = [ (a, b) | (a:rest) <- tails' runs, b <- rest ]
  in length (filter (uncurry (==)) pairs)

tails' :: [a] -> [[a]]
tails' []     = []
tails' (x:xs) = (x:xs) : tails' xs

-- ---- 追加ヘルパー: 入力サイズ事前チェック ----

isValidShuffleInput :: [Int] -> Either String Int
isValidShuffleInput xs
  | null xs                        = Left "input must not be empty"
  | length xs > maxShuffleSize     = Left ("input too large: " ++ show (length xs))
  | length (nub xs) /= length xs   = Left "input contains duplicates"
  | any (< 0) xs                   = Left "input contains negative ids"
  | otherwise                      = Right (length xs)

-- ---- メトリクス ----
-- プロセス全体で 1 つだけ持つ累計カウンタ。unsafePerformIO は IORef 確保のみで純粋。

{-# NOINLINE shufflesTotal #-}
shufflesTotal :: IORef Int
shufflesTotal = unsafePerformIO (newIORef 0)

{-# NOINLINE shuffleErrors #-}
shuffleErrors :: IORef Int
shuffleErrors = unsafePerformIO (newIORef 0)

{-# NOINLINE entropySum #-}
entropySum :: IORef Double
entropySum = unsafePerformIO (newIORef 0.0)

{-# NOINLINE entropyCount #-}
entropyCount :: IORef Int
entropyCount = unsafePerformIO (newIORef 0)

bumpCounter :: IORef Int -> IO ()
bumpCounter ref = atomicModifyIORef' ref (\n -> (n + 1, ()))

recordEntropy :: Double -> IO ()
recordEntropy e = do
  atomicModifyIORef' entropySum   (\s -> (s + e, ()))
  atomicModifyIORef' entropyCount (\n -> (n + 1, ()))

handleMetrics :: IO Response
handleMetrics = do
  s   <- readIORef shufflesTotal
  err <- readIORef shuffleErrors
  es  <- readIORef entropySum
  ec  <- readIORef entropyCount
  let avgE = if ec == 0 then 0.0 else es / fromIntegral ec
  return $ jsonResponse status200 (object
    [ "shuffle_total"          .= s
    , "shuffle_errors_total"   .= err
    , "shuffle_recorded_count" .= ec
    , "shuffle_avg_entropy"    .= avgE
    ])

-- ---- 分布均一性テスト ----
-- 与えられた配列を N 回シャッフルし、各位置に各値が出現した回数の χ² 風統計を返す。
data DistributionRequest = DistributionRequest
  { drIds        :: [Int]
  , drIterations :: Int
  }

instance Data.Aeson.FromJSON DistributionRequest where
  parseJSON = Data.Aeson.withObject "DistributionRequest" $ \v ->
    DistributionRequest
      <$> v Data.Aeson..: "ids"
      <*> v Data.Aeson..: "iterations"

handleDistribution :: Request -> IO Response
handleDistribution req = do
  body <- lazyRequestBody req
  case Data.Aeson.decode body :: Maybe DistributionRequest of
    Nothing -> do
      bumpCounter shuffleErrors
      return $ errorResponse status400 "expected {\"ids\":[...],\"iterations\":N}"
    Just dr
      | drIterations dr < 10 || drIterations dr > 5000 ->
          return $ errorResponse status400 "iterations must be in [10,5000]"
      | length (drIds dr) < 2 || length (drIds dr) > 50 ->
          return $ errorResponse status400 "ids length must be in [2,50]"
      | otherwise -> do
          let n   = length (drIds dr)
              vec = V.fromList (drIds dr)
          runs <- replicateM (drIterations dr) (V.toList <$> fisherYates vec)
          let expected   = fromIntegral (drIterations dr) / fromIntegral n :: Double
              -- position * value -> observed count
              cells      = [ ((pos, v), 1 :: Int) | r <- runs, (pos, v) <- zip [0 ..] r ]
              counts     = Map.fromListWith (+) cells
              chi2 :: Double
              chi2       = sum
                [ let o = fromIntegral (Map.findWithDefault 0 (pos, v) counts) :: Double
                  in (o - expected) ** 2 / expected
                | pos <- [0 .. n - 1]
                , v   <- drIds dr
                ]
              dof        = (n - 1) * (n - 1)
              perPositionFreq =
                [ object
                    [ "position" .= pos
                    , "frequencies" .=
                        [ object
                            [ "value" .= v
                            , "count" .= Map.findWithDefault 0 (pos, v) counts
                            ]
                        | v <- drIds dr
                        ]
                    ]
                | pos <- [0 .. n - 1]
                ]
          return $ jsonResponse status200 (object
            [ "iterations"  .= drIterations dr
            , "size"        .= n
            , "expected"    .= expected
            , "chi_squared" .= chi2
            , "dof"         .= dof
            , "distribution" .= perPositionFreq
            ])

-- ---- 追加ヘルパー: シャッフル結果の独立性チェック ----

countFixedPoints :: [Int] -> [Int] -> Int
countFixedPoints orig shuf
  | length orig /= length shuf = -1
  | otherwise = length (filter id (zipWith (==) orig shuf))

-- 同じ位置のままになった要素の比率（理論期待値は 1/n ≒ 0）
fixedPointRatio :: [Int] -> [Int] -> Double
fixedPointRatio orig shuf =
  case countFixedPoints orig shuf of
    -1 -> -1.0
    n  -> if null orig then 0.0
                       else fromIntegral n / fromIntegral (length orig)

-- ---- /partition: 入力を N グループに均等分割しつつ各グループ内でシャッフル ----
-- 例えば 30 枚のカードを 3 グループに分けて配るときに使う。各グループは Fisher-Yates 済み。

data PartitionRequest = PartitionRequest
  { prIds    :: [Int]
  , prGroups :: Int
  }

instance Data.Aeson.FromJSON PartitionRequest where
  parseJSON = Data.Aeson.withObject "PartitionRequest" $ \v ->
    PartitionRequest <$> v Data.Aeson..: "ids" <*> v Data.Aeson..: "groups"

partitionList :: Int -> [a] -> [[a]]
partitionList g xs
  | g <= 0    = [xs]
  | otherwise =
      let n     = length xs
          base  = n `div` g
          extra = n `mod` g
          sizes = replicate extra (base + 1) ++ replicate (g - extra) base
          go _ []         = []
          go (s:rest) ys  = take s ys : go rest (drop s ys)
          go [] _         = []
      in go sizes xs

handlePartition :: Request -> IO Response
handlePartition req = do
  body <- lazyRequestBody req
  case Data.Aeson.decode body :: Maybe PartitionRequest of
    Nothing -> do
      bumpCounter shuffleErrors
      return $ errorResponse status400 "expected {\"ids\":[...],\"groups\":N}"
    Just pr
      | prGroups pr < 1 || prGroups pr > 32 ->
          return $ errorResponse status400 "groups must be in [1,32]"
      | otherwise -> case validateInput (prIds pr) of
          Left EmptyInput -> return $ errorResponse status400 "empty ids"
          Left (TooManyItems n mx) ->
            return $ errorResponse status400
              ("too many items: " ++ show n ++ " (max " ++ show mx ++ ")")
          Left (InvalidInput msg) -> return $ errorResponse status400 msg
          Right vec -> do
            shuffled <- fisherYates vec
            let groups = partitionList (prGroups pr) (V.toList shuffled)
            bumpCounter shufflesTotal
            recordEntropy (ssEntropy (computeStats shuffled))
            return $ jsonResponse status200 (object
              [ "groups"        .= groups
              , "group_count"   .= prGroups pr
              , "total_items"   .= V.length vec
              , "algorithm"     .= ("fisher-yates+partition" :: String)
              ])

-- ---- /sample: 重み無しの単純サンプリング（重複あり） ----

data SampleRequest = SampleRequest
  { spIds :: [Int]
  , spN   :: Int
  , spReplacement :: Bool
  }

instance Data.Aeson.FromJSON SampleRequest where
  parseJSON = Data.Aeson.withObject "SampleRequest" $ \v ->
    SampleRequest
      <$> v Data.Aeson..: "ids"
      <*> v Data.Aeson..: "n"
      <*> v Data.Aeson..: "replacement"

sampleWithReplacement :: V.Vector Int -> Int -> IO [Int]
sampleWithReplacement vec n = do
  let len = V.length vec
  replicateM n $ do
    idx <- randomRIO (0, len - 1)
    return (vec V.! idx)

sampleWithoutReplacement :: V.Vector Int -> Int -> IO [Int]
sampleWithoutReplacement vec n = do
  shuffled <- fisherYates vec
  return (V.toList (V.take n shuffled))

handleSample :: Request -> IO Response
handleSample req = do
  body <- lazyRequestBody req
  case Data.Aeson.decode body :: Maybe SampleRequest of
    Nothing -> do
      bumpCounter shuffleErrors
      return $ errorResponse status400 "expected {\"ids\":[...],\"n\":N,\"replacement\":bool}"
    Just sp
      | spN sp < 1 -> return $ errorResponse status400 "n must be >= 1"
      | spN sp > maxShuffleSize ->
          return $ errorResponse status400 "n too large"
      | not (spReplacement sp) && spN sp > length (spIds sp) ->
          return $ errorResponse status400 "n exceeds ids length without replacement"
      | otherwise -> case validateInput (spIds sp) of
          Left EmptyInput -> return $ errorResponse status400 "empty ids"
          Left (TooManyItems n mx) ->
            return $ errorResponse status400
              ("too many items: " ++ show n ++ " (max " ++ show mx ++ ")")
          Left (InvalidInput msg) -> return $ errorResponse status400 msg
          Right vec -> do
            sampled <-
              if spReplacement sp
                then sampleWithReplacement vec (spN sp)
                else sampleWithoutReplacement vec (spN sp)
            bumpCounter shufflesTotal
            return $ jsonResponse status200 (object
              [ "sample"      .= sampled
              , "n"           .= spN sp
              , "replacement" .= spReplacement sp
              , "algorithm"   .= ("uniform-sample" :: String)
              ])

-- ---- メイン ----

main :: IO ()
main = do
  portStr <- lookupEnv "PORT"
  let port = fromMaybe 5001 (portStr >>= readMaybe)
  putStrLn $ "shuffle listening on :" ++ show port
  run port $ \req respond -> handleRequest req >>= respond

readMaybe :: String -> Maybe Int
readMaybe s = case reads s of
  [(n, "")] -> Just n
  _         -> Nothing

-- Data.Aeson の FromJSON を使うため追加インポート（GHC拡張）
instance Data.Aeson.FromJSON ShuffleRequest where
  parseJSON v = ShuffleRequest <$> Data.Aeson.parseJSON v
