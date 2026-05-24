package memekaruta.queue

import java.time.Instant

// ---- イベント型定義 ----

sealed trait GameEvent {
  def roomId: String
  def timestamp: Instant
  def eventId: String
}

case class RoomCreated(
    roomId: String,
    hostName: String,
    maxPlayers: Int,
    timestamp: Instant = Instant.now(),
    eventId: String = EventId.next(),
) extends GameEvent

case class PlayerJoined(
    roomId: String,
    playerName: String,
    playerCount: Int,
    timestamp: Instant = Instant.now(),
    eventId: String = EventId.next(),
) extends GameEvent

case class PlayerLeft(
    roomId: String,
    playerName: String,
    reason: String = "voluntary",
    timestamp: Instant = Instant.now(),
    eventId: String = EventId.next(),
) extends GameEvent

case class GameStarted(
    roomId: String,
    players: List[String],
    cardCount: Int,
    settings: GameSettings,
    timestamp: Instant = Instant.now(),
    eventId: String = EventId.next(),
) extends GameEvent

case class CardRead(
    roomId: String,
    cardId: Int,
    cardFuda: String,
    cardIndex: Int,
    totalCards: Int,
    timestamp: Instant = Instant.now(),
    eventId: String = EventId.next(),
) extends GameEvent

case class CardTaken(
    roomId: String,
    cardId: Int,
    winnerName: String,
    responseTimeMs: Long,
    scores: Map[String, Int],
    timestamp: Instant = Instant.now(),
    eventId: String = EventId.next(),
) extends GameEvent

case class CardMissed(
    roomId: String,
    cardId: Int,
    playerName: String,
    timestamp: Instant = Instant.now(),
    eventId: String = EventId.next(),
) extends GameEvent

case class GameOver(
    roomId: String,
    finalScores: Map[String, Int],
    winner: String,
    durationMs: Long,
    cardsTaken: Int,
    timestamp: Instant = Instant.now(),
    eventId: String = EventId.next(),
) extends GameEvent

case class ErrorEvent(
    roomId: String,
    playerName: String,
    errorType: String,
    message: String,
    timestamp: Instant = Instant.now(),
    eventId: String = EventId.next(),
) extends GameEvent

// ---- 設定型 ----

case class GameSettings(
    yomiteMode: String,
    yomiteName: String,
    endMode: String,
    endValue: Int,
)

object GameSettings {
  val default: GameSettings = GameSettings("ai", "", "count", 5)
}

// ---- イベントID生成 ----

object EventId {
  private val counter = new java.util.concurrent.atomic.AtomicLong(0)

  def next(): String = {
    val ts  = Instant.now().toEpochMilli
    val seq = counter.incrementAndGet()
    f"evt-${ts}%d-${seq}%04d"
  }
}

// ---- イベントのシリアライズ補助 ----

object EventSerializer {
  import scala.util.{Try, Success, Failure}

  def toMap(event: GameEvent): Map[String, Any] = event match {
    case e: RoomCreated   => baseMap(e) ++ Map("host_name" -> e.hostName, "max_players" -> e.maxPlayers)
    case e: PlayerJoined  => baseMap(e) ++ Map("player_name" -> e.playerName, "player_count" -> e.playerCount)
    case e: PlayerLeft    => baseMap(e) ++ Map("player_name" -> e.playerName, "reason" -> e.reason)
    case e: GameStarted   => baseMap(e) ++ Map("players" -> e.players, "card_count" -> e.cardCount)
    case e: CardRead      => baseMap(e) ++ Map("card_id" -> e.cardId, "card_fuda" -> e.cardFuda, "index" -> e.cardIndex)
    case e: CardTaken     => baseMap(e) ++ Map("card_id" -> e.cardId, "winner" -> e.winnerName, "response_ms" -> e.responseTimeMs, "scores" -> e.scores)
    case e: CardMissed    => baseMap(e) ++ Map("card_id" -> e.cardId, "player_name" -> e.playerName)
    case e: GameOver      => baseMap(e) ++ Map("winner" -> e.winner, "duration_ms" -> e.durationMs, "cards_taken" -> e.cardsTaken, "scores" -> e.finalScores)
    case e: ErrorEvent    => baseMap(e) ++ Map("player_name" -> e.playerName, "error_type" -> e.errorType, "message" -> e.message)
  }

  private def baseMap(e: GameEvent): Map[String, Any] = Map(
    "event_id"  -> e.eventId,
    "event_type" -> eventTypeName(e),
    "room_id"   -> e.roomId,
    "timestamp" -> e.timestamp.toString,
  )

  def eventTypeName(e: GameEvent): String = e match {
    case _: RoomCreated  => "room_created"
    case _: PlayerJoined => "player_joined"
    case _: PlayerLeft   => "player_left"
    case _: GameStarted  => "game_started"
    case _: CardRead     => "card_read"
    case _: CardTaken    => "card_taken"
    case _: CardMissed   => "card_missed"
    case _: GameOver     => "game_over"
    case _: ErrorEvent   => "error"
  }
}

// ---- 追加イベント型 ----

case class EventSnapshot(
    roomId: String,
    eventCount: Int,
    lastEventId: String,
    capturedAt: Instant = Instant.now(),
    timestamp: Instant = Instant.now(),
    eventId: String = EventId.next(),
) extends GameEvent

case class EventReplay(
    roomId: String,
    fromEventId: String,
    toEventId: String,
    eventCount: Int,
    timestamp: Instant = Instant.now(),
    eventId: String = EventId.next(),
) extends GameEvent

// ---- 永続化に使う簡易JSONエンコーダ ----
// 外部の json4s/circe 等に依存せず、Map[String, Any] を JSONL 互換で書き出すための最小実装。
object JsonLine {
  def encode(m: Map[String, Any]): String = "{" + m.toSeq.map { case (k, v) => quote(k) + ":" + value(v) }.mkString(",") + "}"

  private def value(v: Any): String = v match {
    case null            => "null"
    case s: String       => quote(s)
    case n: Int          => n.toString
    case n: Long         => n.toString
    case n: Double       => n.toString
    case b: Boolean      => b.toString
    case xs: Seq[_]      => "[" + xs.map(value).mkString(",") + "]"
    case xs: List[_]     => "[" + xs.map(value).mkString(",") + "]"
    case m: Map[_, _]    => "{" + m.toSeq.map { case (k, v2) => quote(k.toString) + ":" + value(v2) }.mkString(",") + "}"
    case other           => quote(other.toString)
  }

  private def quote(s: String): String = {
    val sb = new StringBuilder("\"")
    s.foreach {
      case '"'  => sb.append("\\\"")
      case '\\' => sb.append("\\\\")
      case '\n' => sb.append("\\n")
      case '\r' => sb.append("\\r")
      case '\t' => sb.append("\\t")
      case c if c < 0x20 => sb.append(f"\\u${c.toInt}%04x")
      case c    => sb.append(c)
    }
    sb.append('"').toString
  }
}

// ---- イベントフィルタ ----

object EventFilter {
  def byRoom(events: Seq[GameEvent], roomId: String): Seq[GameEvent] =
    events.filter(_.roomId == roomId)

  def byType[T <: GameEvent](events: Seq[GameEvent])(implicit ct: scala.reflect.ClassTag[T]): Seq[T] =
    events.collect { case e: T => e }

  def between(events: Seq[GameEvent], from: Instant, to: Instant): Seq[GameEvent] =
    events.filter(e => !e.timestamp.isBefore(from) && !e.timestamp.isAfter(to))

  def cardTakenByPlayer(events: Seq[GameEvent], playerName: String): Seq[CardTaken] =
    byType[CardTaken](events).filter(_.winnerName == playerName)

  def gameOverEvents(events: Seq[GameEvent]): Seq[GameOver] =
    byType[GameOver](events)
}
