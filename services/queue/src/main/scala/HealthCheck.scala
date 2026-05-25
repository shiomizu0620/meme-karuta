package memekaruta.queue

import java.time.Instant
import java.util.concurrent.atomic.AtomicReference

/**
 * Queue サービスのヘルスチェック実装。
 * docker / nginx 上流から /health を叩かれる想定。
 *
 * 単純な「プロセス生存」だけでなく、最後のイベント処理時刻からの経過時間や
 * Backpressure の状態も含めて返すことで、運用側でステータスを判断しやすくする。
 */
class HealthCheck(backpressure: Backpressure) {

  private val startedAt = Instant.now()
  private val lastEventAt = new AtomicReference[Option[Instant]](None)
  private val ready = new java.util.concurrent.atomic.AtomicBoolean(false)

  def markReady(): Unit = ready.set(true)

  def markEventProcessed(): Unit = lastEventAt.set(Some(Instant.now()))

  def isReady: Boolean = ready.get()

  def report: HealthReport = {
    val now = Instant.now()
    val uptime = java.time.Duration.between(startedAt, now).toSeconds
    val secondsSinceLastEvent = lastEventAt.get().map { ts =>
      java.time.Duration.between(ts, now).toSeconds
    }
    val staleness = secondsSinceLastEvent.exists(_ > 300L) // 5 分以上イベントが無いと stale
    val pressure = !backpressure.metrics.get("accepting").contains(1L)

    HealthReport(
      ready = isReady,
      uptimeSecs = uptime,
      secondsSinceLastEvent = secondsSinceLastEvent,
      isStale = staleness,
      isUnderPressure = pressure,
    )
  }
}

case class HealthReport(
  ready: Boolean,
  uptimeSecs: Long,
  secondsSinceLastEvent: Option[Long],
  isStale: Boolean,
  isUnderPressure: Boolean,
) {

  /** HTTP ステータスコードに変換する。 */
  def httpStatus: Int = {
    if (!ready) 503
    else if (isStale || isUnderPressure) 503
    else 200
  }

  def asJson: String = {
    val lastEventField = secondsSinceLastEvent
      .map(v => s""""seconds_since_last_event":$v""")
      .getOrElse(""""seconds_since_last_event":null""")
    s"""{"ready":$ready,"uptime_secs":$uptimeSecs,$lastEventField,"is_stale":$isStale,"under_pressure":$isUnderPressure}"""
  }
}
