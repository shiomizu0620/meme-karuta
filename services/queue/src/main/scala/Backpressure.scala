package memekaruta.queue

import java.util.concurrent.atomic.{AtomicInteger, AtomicLong}
import scala.concurrent.duration._

/**
 * Queue 全体の流量制御 (backpressure)。
 *
 * イベント生成側 (realtime / judge) が一気に大量のイベントを投げてきた時、
 * Scala 側の処理が追いつかずキューが溢れることがある。
 * このクラスはキューの逼迫度を観測し、上流に「いま受け入れ可能か」を答える。
 *
 * - watermark を超えると `accept=false` になる
 * - 低水位 (lowWatermark) を下回るまで戻らない（バウンス防止）
 * - 上流は次のチャンスまで指数バックオフで待つ
 */
class Backpressure(
  highWatermark: Int,
  lowWatermark: Int,
) {
  require(lowWatermark < highWatermark, "lowWatermark must be < highWatermark")

  private val depth = new AtomicInteger(0)
  private val accepting = new java.util.concurrent.atomic.AtomicBoolean(true)
  private val totalRejected = new AtomicLong(0L)
  private val totalAccepted = new AtomicLong(0L)

  /** 1 件の追加を試みる。受け入れ可能なら true。 */
  def tryAcquire(): Boolean = {
    if (!accepting.get()) {
      totalRejected.incrementAndGet()
      return false
    }
    val newDepth = depth.incrementAndGet()
    if (newDepth >= highWatermark) {
      accepting.set(false)
    }
    totalAccepted.incrementAndGet()
    true
  }

  /** 1 件の処理完了を通知する。 */
  def release(): Unit = {
    val newDepth = depth.decrementAndGet()
    if (newDepth <= lowWatermark && !accepting.get()) {
      accepting.set(true)
    }
  }

  /** 上流が次に試すまでの推奨待ち時間。 */
  def suggestedBackoff(): FiniteDuration = {
    val d = depth.get()
    if (d <= lowWatermark) 0.millis
    else if (d <= highWatermark) ((d - lowWatermark) * 5).millis
    else (highWatermark * 5).millis
  }

  def metrics: Map[String, Long] = Map(
    "depth"          -> depth.get().toLong,
    "high_watermark" -> highWatermark.toLong,
    "low_watermark"  -> lowWatermark.toLong,
    "accepting"      -> (if (accepting.get()) 1L else 0L),
    "accepted_total" -> totalAccepted.get(),
    "rejected_total" -> totalRejected.get(),
  )

  def summary: String = {
    val d = depth.get()
    val a = if (accepting.get()) "yes" else "no"
    s"depth=$d/$highWatermark accepting=$a accepted=${totalAccepted.get()} rejected=${totalRejected.get()}"
  }
}

object Backpressure {
  /** Queue.scala のデフォルト値を踏襲した設定。 */
  def default: Backpressure = new Backpressure(highWatermark = 1000, lowWatermark = 700)
}
