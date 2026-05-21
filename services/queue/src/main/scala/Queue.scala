package memekaruta.queue

import java.time.Instant
import java.util.concurrent.{ConcurrentLinkedDeque, LinkedBlockingQueue, TimeUnit}
import java.util.concurrent.atomic.AtomicBoolean
import scala.collection.concurrent.TrieMap
import scala.util.{Failure, Success, Try}

// ---- メインのキュー処理サービス ----

class EventQueueService(storage: EventStorage, analytics: AnalyticsEngine) {

  private val queue     = new LinkedBlockingQueue[GameEvent](10000)
  private val running   = new AtomicBoolean(false)
  private var workerThread: Option[Thread] = None

  def start(): Unit = {
    if (!running.compareAndSet(false, true)) return
    val t = new Thread(() => processLoop(), "event-queue-worker")
    t.setDaemon(true)
    t.start()
    workerThread = Some(t)
    println(s"[Queue] Worker started")
  }

  def stop(): Unit = {
    running.set(false)
    workerThread.foreach(_.interrupt())
    workerThread = None
    println(s"[Queue] Worker stopped")
  }

  def publish(event: GameEvent): Boolean = {
    val ok = queue.offer(event, 100, TimeUnit.MILLISECONDS)
    if (!ok) System.err.println(s"[Queue] WARN: queue full, dropped ${EventSerializer.eventTypeName(event)}")
    ok
  }

  def queueSize: Int = queue.size()

  private def processLoop(): Unit = {
    while (running.get()) {
      Try(Option(queue.poll(500, TimeUnit.MILLISECONDS))) match {
        case Success(Some(event)) => handleEvent(event)
        case Success(None)        => // timeout, loop again
        case Failure(_)           => // interrupted
      }
    }
  }

  private def handleEvent(event: GameEvent): Unit = {
    Try {
      storage.append(event)
      analytics.process(event)
      logEvent(event)
    }.recover { case e => System.err.println(s"[Queue] ERROR processing ${event.eventId}: ${e.getMessage}") }
  }

  private def logEvent(event: GameEvent): Unit = {
    val ts   = event.timestamp.toString.take(23)
    val typ  = EventSerializer.eventTypeName(event).padEnd(16)
    val room = event.roomId.padEnd(8)
    println(s"[Queue] $ts  $typ  room=$room  id=${event.eventId}")
  }
}

// ---- ストレージ ----

class EventStorage {
  private val store = new TrieMap[String, ConcurrentLinkedDeque[GameEvent]]()

  def append(event: GameEvent): Unit = {
    val deque = store.getOrElseUpdate(event.roomId, new ConcurrentLinkedDeque())
    deque.addLast(event)
  }

  def findByRoom(roomId: String): Seq[GameEvent] = {
    store.get(roomId).map(d => d.toArray(Array.empty[GameEvent]).toSeq).getOrElse(Seq.empty)
  }

  def findAll(): Seq[GameEvent] =
    store.values.flatMap(d => d.toArray(Array.empty[GameEvent]).toSeq).toSeq
      .sortBy(_.timestamp)

  def countByRoom(roomId: String): Int =
    store.get(roomId).map(_.size()).getOrElse(0)

  def deleteRoom(roomId: String): Boolean =
    store.remove(roomId).isDefined

  def roomIds: Set[String] = store.keySet.toSet

  def totalEvents: Int = store.values.map(_.size()).sum
}

// ---- アナリティクスエンジン ----

class AnalyticsEngine {
  private val roomStats = new TrieMap[String, RoomStats]()

  def process(event: GameEvent): Unit = {
    val stats = roomStats.getOrElseUpdate(event.roomId, RoomStats(event.roomId))
    roomStats.update(event.roomId, stats.update(event))
  }

  def statsForRoom(roomId: String): Option[RoomStats] = roomStats.get(roomId)

  def allStats(): Map[String, RoomStats] = roomStats.toMap

  def topPlayers(limit: Int = 10): Seq[(String, Int)] = {
    val allScores = roomStats.values.flatMap(_.playerTotalScores).toSeq
    allScores.groupMapReduce(_._1)(_._2)(_ + _)
      .toSeq.sortBy(-_._2).take(limit)
  }
}

case class RoomStats(
    roomId: String,
    playerScores: Map[String, Int]   = Map.empty,
    cardsTaken: Int                  = 0,
    cardsMissed: Int                 = 0,
    gameCount: Int                   = 0,
    playerJoins: Int                 = 0,
    totalResponseMs: Long            = 0L,
    responseCount: Int               = 0,
    startedAt: Option[Instant]       = None,
    finishedAt: Option[Instant]      = None,
    errorCount: Int                  = 0,
) {
  def update(event: GameEvent): RoomStats = event match {
    case e: PlayerJoined => copy(playerJoins = playerJoins + 1)
    case e: GameStarted  => copy(gameCount = gameCount + 1, startedAt = Some(e.timestamp),
                                  playerScores = e.players.map(_ -> 0).toMap)
    case e: CardTaken    => copy(
      cardsTaken    = cardsTaken + 1,
      playerScores  = playerScores.updatedWith(e.winnerName)(_.map(_ + 1).orElse(Some(1))),
      totalResponseMs = totalResponseMs + e.responseTimeMs,
      responseCount = responseCount + 1,
    )
    case e: CardMissed   => copy(cardsMissed = cardsMissed + 1)
    case e: GameOver     => copy(finishedAt = Some(e.timestamp), playerScores = e.finalScores)
    case e: ErrorEvent   => copy(errorCount = errorCount + 1)
    case _ => this
  }

  def averageResponseMs: Double =
    if (responseCount == 0) 0.0 else totalResponseMs.toDouble / responseCount

  def durationMs: Option[Long] = for {
    s <- startedAt
    f <- finishedAt
  } yield f.toEpochMilli - s.toEpochMilli

  def winner: Option[String] =
    playerScores.maxByOption(_._2).map(_._1)

  def playerTotalScores: Map[String, Int] = playerScores

  def toSummary: Map[String, Any] = Map(
    "room_id"          -> roomId,
    "game_count"       -> gameCount,
    "cards_taken"      -> cardsTaken,
    "cards_missed"     -> cardsMissed,
    "player_joins"     -> playerJoins,
    "avg_response_ms"  -> f"${averageResponseMs}%.1f",
    "duration_ms"      -> durationMs.map(_.toString).getOrElse("ongoing"),
    "winner"           -> winner.getOrElse("none"),
    "error_count"      -> errorCount,
    "scores"           -> playerScores,
  )
}

// ---- HTTP API サーバー ----

class QueueHttpServer(
    service: EventQueueService,
    storage: EventStorage,
    analytics: AnalyticsEngine,
    port: Int = 5003,
) {
  import java.net.{ServerSocket, Socket}
  import java.io.{BufferedReader, InputStreamReader, PrintWriter}

  private val running = new AtomicBoolean(false)

  def start(): Unit = {
    running.set(true)
    val server = new ServerSocket(port)
    println(s"[Queue HTTP] Listening on :$port")

    val t = new Thread(() => {
      while (running.get()) {
        Try(server.accept()).foreach { sock =>
          new Thread(() => handleRequest(sock), "http-handler").start()
        }
      }
    }, "http-acceptor")
    t.setDaemon(true)
    t.start()
  }

  private def handleRequest(sock: Socket): Unit = {
    Try {
      val in  = new BufferedReader(new InputStreamReader(sock.getInputStream))
      val out = new PrintWriter(sock.getOutputStream, true)

      val requestLine = in.readLine()
      if (requestLine == null) { sock.close(); return }

      val parts  = requestLine.split(" ")
      val method = parts(0)
      val path   = if (parts.length > 1) parts(1) else "/"

      var contentLength = 0
      var line = in.readLine()
      while (line != null && line.nonEmpty) {
        if (line.toLowerCase.startsWith("content-length:"))
          contentLength = line.split(":")(1).trim.toInt
        line = in.readLine()
      }

      val body = if (contentLength > 0) {
        val buf = new Array[Char](contentLength)
        in.read(buf, 0, contentLength)
        new String(buf)
      } else ""

      val (status, responseBody) = route(method, path, body)
      sendResponse(out, status, responseBody)
    }.recover { case e => System.err.println(s"[Queue HTTP] Error: ${e.getMessage}") }
      .foreach(_ => Try(sock.close()))
  }

  private def route(method: String, path: String, body: String): (Int, String) = {
    (method, path) match {
      case ("GET", "/health") =>
        200 -> s"""{"status":"ok","queue_size":${service.queueSize},"total_events":${storage.totalEvents}}"""

      case ("GET", p) if p.startsWith("/stats/") =>
        val roomId = p.stripPrefix("/stats/")
        analytics.statsForRoom(roomId) match {
          case Some(stats) => 200 -> mapToJson(stats.toSummary)
          case None        => 404 -> """{"error":"room not found"}"""
        }

      case ("GET", "/stats") =>
        val all = analytics.allStats().values.map(s => mapToJson(s.toSummary)).mkString("[", ",", "]")
        200 -> all

      case ("GET", p) if p.startsWith("/events/") =>
        val roomId = p.stripPrefix("/events/")
        val events = storage.findByRoom(roomId)
        val json   = events.map(e => mapToJson(EventSerializer.toMap(e))).mkString("[", ",", "]")
        200 -> json

      case ("GET", "/top-players") =>
        val top  = analytics.topPlayers(10)
        val json = top.zipWithIndex.map { case ((name, score), i) =>
          s"""{"rank":${i+1},"player":"$name","total_score":$score}"""
        }.mkString("[", ",", "]")
        200 -> json

      case _ => 404 -> """{"error":"not found"}"""
    }
  }

  private def sendResponse(out: PrintWriter, status: Int, body: String): Unit = {
    val statusText = status match { case 200 => "OK"; case 404 => "Not Found"; case _ => "Error" }
    out.print(s"HTTP/1.1 $status $statusText\r\n")
    out.print("Content-Type: application/json; charset=utf-8\r\n")
    out.print(s"Content-Length: ${body.getBytes("UTF-8").length}\r\n")
    out.print("Access-Control-Allow-Origin: *\r\n")
    out.print("\r\n")
    out.print(body)
    out.flush()
  }

  private def mapToJson(m: Map[String, Any]): String = {
    val pairs = m.map { case (k, v) =>
      val valJson = v match {
        case s: String              => s""""${s.replace("\"", "\\\"")}""""
        case n: Int                 => n.toString
        case n: Long                => n.toString
        case d: Double              => f"$d%.2f"
        case b: Boolean             => b.toString
        case mm: Map[_, _]          => mapToJson(mm.asInstanceOf[Map[String, Any]])
        case seq: Seq[_]            => seq.map(x => s""""$x"""").mkString("[", ",", "]")
        case null | None            => "null"
        case Some(x)                => s""""$x""""
        case other                  => s""""$other""""
      }
      s""""$k":$valJson"""
    }
    pairs.mkString("{", ",", "}")
  }
}

// ---- メインエントリポイント ----

object Main extends App {
  val storage   = new EventStorage()
  val analytics = new AnalyticsEngine()
  val service   = new EventQueueService(storage, analytics)
  val port      = sys.env.getOrElse("PORT", "5003").toInt
  val server    = new QueueHttpServer(service, storage, analytics, port)

  service.start()
  server.start()

  println(s"[Queue] Service running on :$port")

  Runtime.getRuntime.addShutdownHook(new Thread(() => {
    println("[Queue] Shutting down...")
    service.stop()
  }))

  Thread.currentThread().join()
}
