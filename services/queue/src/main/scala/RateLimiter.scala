package memekaruta.queue

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import scala.concurrent.duration._

/**
 * 単純なトークンバケット型レートリミッタ。
 *
 * イベント送信元 (room_id 単位) ごとに「秒間 N イベントまで」を許容する。
 * judge と違って Queue は履歴保管が主目的なので、瞬間ピークより
 * 中長期的なバランスを取ることが大事。
 */
class RateLimiter(capacity: Int, refillPerSec: Double) {
  require(capacity > 0, "capacity must be positive")
  require(refillPerSec > 0.0, "refillPerSec must be positive")

  private val buckets = new ConcurrentHashMap[String, Bucket]()

  def tryAcquire(key: String): Boolean = {
    val bucket = buckets.computeIfAbsent(key, _ => new Bucket(capacity.toDouble))
    bucket.tryConsume(refillPerSec, capacity)
  }

  def reset(key: String): Unit = {
    buckets.remove(key)
  }

  def activeKeys: Int = buckets.size

  /** 全バケットをまとめてクリアする。テスト用。 */
  def clearAll(): Unit = buckets.clear()

  /** 現在のキーと残量のスナップショット。監視用。 */
  def snapshot: Map[String, Double] = {
    import scala.jdk.CollectionConverters._
    buckets.asScala.iterator.map { case (k, b) => k -> b.peekTokens }.toMap
  }

  private class Bucket(initial: Double) {
    private var tokens: Double = initial
    private var lastRefill: Long = System.nanoTime()

    def tryConsume(rate: Double, cap: Int): Boolean = synchronized {
      val now = System.nanoTime()
      val elapsedSec = (now - lastRefill) / 1e9
      lastRefill = now
      tokens = math.min(cap.toDouble, tokens + elapsedSec * rate)
      if (tokens >= 1.0) {
        tokens -= 1.0
        true
      } else {
        false
      }
    }

    def peekTokens: Double = synchronized(tokens)
  }
}
