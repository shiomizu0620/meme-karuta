module Main (main) where

import Control.Monad (forM_, replicateM, when)
import Data.Aeson (ToJSON, decode, encode, object, (.=))
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

    (_, "/shuffle")         -> return $ errorResponse status405 "POST required"
    (_, "/shuffle/sattolo") -> return $ errorResponse status405 "POST required"
    (_, "/shuffle/seed")    -> return $ errorResponse status405 "POST required"
    (_, "/stats")           -> return $ errorResponse status405 "POST required"
    _                       -> return $ errorResponse status404 "not found"

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

-- ---- メイン ----

main :: IO ()
main = do
  portStr <- lookupEnv "PORT"
  let port = fromMaybe 5001 (portStr >>= readMaybe)
  putStrLn $ "shuffle listening on :" ++ show port
  run port handleRequest

readMaybe :: String -> Maybe Int
readMaybe s = case reads s of
  [(n, "")] -> Just n
  _         -> Nothing

-- Data.Aeson の FromJSON を使うため追加インポート（GHC拡張）
instance Data.Aeson.FromJSON ShuffleRequest where
  parseJSON v = ShuffleRequest <$> Data.Aeson.parseJSON v
