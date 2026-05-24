package memekaruta.queue

import java.time.Instant
import java.util.concurrent.atomic.{AtomicLong, AtomicReference}
import scala.collection.concurrent.TrieMap

/** イベントキュー処理サービス用のメトリクス収集器。Prometheus 風テキスト出力対応。 */
class QueueMetrics {

  private val eventsByType = new TrieMap[String, AtomicLong]()
  private val eventsByRoom = new TrieMap[String, AtomicLong]()
  private val errorsByType = new TrieMap[String, AtomicLong]()
  private val droppedTotal  = new AtomicLong(0L)
  private val processedTotal = new AtomicLong(0L)
  private val processLatencyNsSum   = new AtomicLong(0L)
  private val processLatencyNsCount = new AtomicLong(0L)
  private val deadLetterCount = new AtomicLong(0L)
  private val startedAt = new AtomicReference[Instant](Instant.now())

  /** キューに publish された生イベントを記録。 */
  def onPublish(event: GameEvent): Unit = {
    incCounter(eventsByType, EventSerializer.eventTypeName(event))
    incCounter(eventsByRoom, event.roomId)
  }

  /** キューが満杯で publish できなかった場合の記録。 */
  def onDropped(): Unit = {
    droppedTotal.incrementAndGet()
  }

  /** ワーカーが 1 件処理した際に呼ぶ。 */
  def onProcessed(elapsedNs: Long): Unit = {
    processedTotal.incrementAndGet()
    processLatencyNsSum.addAndGet(elapsedNs)
    processLatencyNsCount.incrementAndGet()
  }

  /** 処理失敗ログ。 */
  def onError(typeName: String): Unit = {
    incCounter(errorsByType, typeName)
  }

  /** Dead-letter queue に積まれたイベントを記録。 */
  def onDeadLetter(): Unit = {
    deadLetterCount.incrementAndGet()
  }

  def reset(): Unit = {
    eventsByType.clear()
    eventsByRoom.clear()
    errorsByType.clear()
    droppedTotal.set(0L)
    processedTotal.set(0L)
    processLatencyNsSum.set(0L)
    processLatencyNsCount.set(0L)
    deadLetterCount.set(0L)
    startedAt.set(Instant.now())
  }

  def avgProcessLatencyMs: Double = {
    val c = processLatencyNsCount.get()
    if (c == 0L) 0.0
    else processLatencyNsSum.get().toDouble / c.toDouble / 1_000_000.0
  }

  def snapshot: Map[String, Any] = Map(
    "events_total"        -> processedTotal.get(),
    "events_dropped"      -> droppedTotal.get(),
    "events_dead_letter"  -> deadLetterCount.get(),
    "avg_process_ms"      -> f"$avgProcessLatencyMs%.3f",
    "uptime_sec"          -> (Instant.now().getEpochSecond - startedAt.get().getEpochSecond),
    "unique_rooms"        -> eventsByRoom.size,
    "event_types_seen"    -> eventsByType.size,
  )

  /** Prometheus テキスト形式で書き出す。 */
  def renderPrometheus: String = {
    val sb = new StringBuilder

    sb ++= "# HELP queue_events_total Number of events processed by the queue worker\n"
    sb ++= "# TYPE queue_events_total counter\n"
    sb ++= s"queue_events_total ${processedTotal.get()}\n"

    sb ++= "# HELP queue_events_dropped Number of events dropped because the queue was full\n"
    sb ++= "# TYPE queue_events_dropped counter\n"
    sb ++= s"queue_events_dropped ${droppedTotal.get()}\n"

    sb ++= "# HELP queue_dead_letter_total Number of events sent to the dead-letter queue\n"
    sb ++= "# TYPE queue_dead_letter_total counter\n"
    sb ++= s"queue_dead_letter_total ${deadLetterCount.get()}\n"

    sb ++= "# HELP queue_process_latency_avg_ms Average per-event processing latency in ms\n"
    sb ++= "# TYPE queue_process_latency_avg_ms gauge\n"
    sb ++= f"queue_process_latency_avg_ms ${avgProcessLatencyMs}%.4f\n"

    sb ++= "# HELP queue_events_by_type_total Events grouped by event type\n"
    sb ++= "# TYPE queue_events_by_type_total counter\n"
    eventsByType.toSeq.sortBy(_._1).foreach { case (t, c) =>
      sb ++= s"""queue_events_by_type_total{type="$t"} ${c.get()}\n"""
    }

    sb ++= "# HELP queue_errors_by_type_total Errors grouped by originating event type\n"
    sb ++= "# TYPE queue_errors_by_type_total counter\n"
    errorsByType.toSeq.sortBy(_._1).foreach { case (t, c) =>
      sb ++= s"""queue_errors_by_type_total{type="$t"} ${c.get()}\n"""
    }

    sb.toString
  }

  private def incCounter(map: TrieMap[String, AtomicLong], key: String): Unit = {
    val counter = map.getOrElseUpdate(key, new AtomicLong(0L))
    counter.incrementAndGet()
    ()
  }
}

object QueueMetrics {
  // グローバルアクセス用の lazy インスタンス。テストでは新規の QueueMetrics を使う。
  lazy val global: QueueMetrics = new QueueMetrics
}
