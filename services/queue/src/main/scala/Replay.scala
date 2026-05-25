package memekaruta.queue

import scala.collection.mutable
import scala.util.{Failure, Success, Try}

/**
 * イベントキューのリプレイ機能。
 *
 * ゲーム終了後のスコア集計や、不具合再現のために過去のイベント列を
 * 順番にもう一度処理する。Queue 本体は副作用付きでイベントを受け取るが、
 * リプレイは純粋関数的に「最終状態」と「中間スナップショット」を作る。
 *
 * 設計上のポイント:
 *  - 入力イベントが時系列順でない場合は再ソートする
 *  - 不正イベントはエラー報告に集約し、リプレイ全体は止めない
 *  - 大量イベントでもメモリ過剰消費しないように、スナップショットは
 *    `everyN` 個ごとに 1 枚だけ取る
 */
object Replay {

  /** リプレイの最終結果。 */
  case class Result(
    finalState: GameState,
    snapshots: Seq[GameState],
    rejected: Seq[ReplayError],
    processed: Int,
  ) {
    def isClean: Boolean = rejected.isEmpty
    def summary: String =
      s"processed=$processed rejected=${rejected.size} winner=${finalState.winnerName.getOrElse("(none)")}"
  }

  /** リプレイ中に発生したイベント単位のエラー。 */
  case class ReplayError(
    index: Int,
    event: GameEvent,
    message: String,
  )

  /** ゲームの実行中状態。 */
  case class GameState(
    roomId: String,
    players: Map[String, Int], // player_id -> score
    cardsTaken: Set[Long],
    isFinished: Boolean,
  ) {
    def winnerName: Option[String] =
      if (players.isEmpty) None
      else Some(players.toSeq.maxBy(_._2)._1)
  }

  object GameState {
    def empty(roomId: String): GameState =
      GameState(roomId, Map.empty, Set.empty, isFinished = false)
  }

  /** イベント列をリプレイする本体。 */
  def replay(events: Seq[GameEvent], everyN: Int = 10): Result = {
    val sorted = events.sortBy(_.timestampMs)
    val rejected = mutable.ArrayBuffer.empty[ReplayError]
    val snapshots = mutable.ArrayBuffer.empty[GameState]
    var state = initialState(sorted)
    var processed = 0

    for ((event, idx) <- sorted.zipWithIndex) {
      apply(state, event) match {
        case Success(next) =>
          state = next
          processed += 1
          if (everyN > 0 && processed % everyN == 0) {
            snapshots += state
          }
        case Failure(ex) =>
          rejected += ReplayError(idx, event, Option(ex.getMessage).getOrElse("unknown"))
      }
    }

    Result(state, snapshots.toSeq, rejected.toSeq, processed)
  }

  /** イベント 1 個を状態に適用する。失敗時は Failure を返す。 */
  def apply(state: GameState, event: GameEvent): Try[GameState] = Try {
    if (state.isFinished) {
      throw new IllegalStateException(s"game already finished, ignoring ${event.eventType}")
    }
    event match {
      case e: GameEvent.RoomCreated =>
        if (state.roomId != e.roomId)
          throw new IllegalArgumentException(s"room id mismatch: ${state.roomId} vs ${e.roomId}")
        state

      case e: GameEvent.PlayerJoined =>
        if (state.players.contains(e.playerId))
          throw new IllegalArgumentException(s"duplicate player: ${e.playerId}")
        state.copy(players = state.players + (e.playerId -> 0))

      case e: GameEvent.PlayerLeft =>
        state.copy(players = state.players - e.playerId)

      case e: GameEvent.CardTaken =>
        if (state.cardsTaken.contains(e.cardId))
          throw new IllegalArgumentException(s"card already taken: ${e.cardId}")
        if (!state.players.contains(e.playerId))
          throw new IllegalArgumentException(s"unknown player: ${e.playerId}")
        val newScore = state.players(e.playerId) + 1
        state.copy(
          players = state.players + (e.playerId -> newScore),
          cardsTaken = state.cardsTaken + e.cardId,
        )

      case _: GameEvent.GameFinished =>
        state.copy(isFinished = true)
    }
  }

  /** RoomCreated イベントが先頭にある前提で初期状態を作る。 */
  private def initialState(events: Seq[GameEvent]): GameState = {
    events.headOption match {
      case Some(e: GameEvent.RoomCreated) => GameState.empty(e.roomId)
      case _                              => GameState.empty("unknown")
    }
  }
}
