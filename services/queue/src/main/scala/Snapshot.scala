package memekaruta.queue

import java.time.Instant
import java.util.concurrent.atomic.AtomicLong
import scala.collection.mutable

/**
 * 進行中ゲームのスナップショット保存/復元。
 *
 * Queue 本体は再起動すると in-memory な状態が消えるので、定期的にスナップショットを
 * 取り、再起動後にロードして「ほぼ同じ状態」から再開する。
 *
 * - スナップショットは JSON 風のシリアライズを自前で行う（依存追加を避けるため）
 * - 同一 roomId に対する書き込みは順序保証する
 * - 古いスナップショットは TTL で破棄
 */
object Snapshot {

  case class Entry(
    roomId: String,
    createdAtMs: Long,
    payload: String,
  )

  /** 簡易なメモリ上ストア。実運用では Redis や S3 を想定。 */
  class Store(ttlMs: Long = 60L * 60L * 1000L) {
    private val data = mutable.LinkedHashMap.empty[String, Entry]
    private val writes = new AtomicLong(0L)
    private val reads = new AtomicLong(0L)

    def put(roomId: String, payload: String): Entry = synchronized {
      val entry = Entry(roomId, Instant.now().toEpochMilli, payload)
      data.put(roomId, entry)
      writes.incrementAndGet()
      sweepExpired()
      entry
    }

    def get(roomId: String): Option[Entry] = synchronized {
      reads.incrementAndGet()
      data.get(roomId).filter(notExpired)
    }

    def remove(roomId: String): Boolean = synchronized {
      data.remove(roomId).isDefined
    }

    def size: Int = synchronized { data.size }

    def stats: Map[String, Long] = Map(
      "writes_total" -> writes.get(),
      "reads_total"  -> reads.get(),
      "entries"      -> size.toLong,
      "ttl_ms"       -> ttlMs,
    )

    private def notExpired(entry: Entry): Boolean = {
      val now = Instant.now().toEpochMilli
      now - entry.createdAtMs < ttlMs
    }

    private def sweepExpired(): Unit = {
      val now = Instant.now().toEpochMilli
      val toRemove = data.collect {
        case (k, v) if now - v.createdAtMs >= ttlMs => k
      }
      toRemove.foreach(data.remove)
    }
  }

  /** GameState を最小限のテキスト形式にシリアライズ。 */
  def serialize(state: Replay.GameState): String = {
    val players = state.players.toSeq.sortBy(_._1).map { case (k, v) => s"$k=$v" }.mkString(",")
    val taken = state.cardsTaken.toSeq.sorted.mkString(",")
    s"room=${state.roomId}|players=$players|taken=$taken|finished=${state.isFinished}"
  }

  /** serialize で書いた形式を読み戻す。 */
  def deserialize(s: String): Option[Replay.GameState] = {
    val sections = s.split("\\|").map(_.split("=", 2))
    val map = sections.collect { case Array(k, v) => k -> v }.toMap

    for {
      roomId <- map.get("room")
    } yield {
      val players = map.getOrElse("players", "")
        .split(",").toSeq.filter(_.nonEmpty)
        .map(_.split("=", 2))
        .collect { case Array(k, v) => k -> v.toIntOption.getOrElse(0) }
        .toMap

      val taken = map.getOrElse("taken", "")
        .split(",").toSeq.filter(_.nonEmpty)
        .flatMap(s => s.toLongOption)
        .toSet

      val finished = map.get("finished").exists(_.equalsIgnoreCase("true"))

      Replay.GameState(roomId, players, taken, finished)
    }
  }
}
