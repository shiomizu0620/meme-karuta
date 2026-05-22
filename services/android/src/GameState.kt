package com.example.memekaruta

import org.json.JSONObject

class GameState {
    enum class Status { IDLE, CONNECTING, WAITING, PLAYING, FINISHED, ERROR }

    var status: Status = Status.IDLE
    var roomId: String = ""
    var players: List<String> = emptyList()
    var playerName: String = ""
    var isHost: Boolean = false
    var currentCardIndex: Int = -1
    var takenCardIds: MutableSet<Int> = mutableSetOf()
    var scores: Map<String, Int> = emptyMap()
    var totalCards: Int = 0
    var errorMessage: String = ""
    var lastEventTime: Long = System.currentTimeMillis()

    fun reset() {
        status = Status.IDLE
        roomId = ""
        players = emptyList()
        playerName = ""
        isHost = false
        currentCardIndex = -1
        takenCardIds = mutableSetOf()
        scores = emptyMap()
        totalCards = 0
        errorMessage = ""
        lastEventTime = System.currentTimeMillis()
    }

    fun myScore(): Int = scores[playerName] ?: 0
    fun remainingCount(): Int = (totalCards - takenCardIds.size).coerceAtLeast(0)
    fun rankedPlayers(): List<Pair<String, Int>> =
        scores.entries.sortedByDescending { it.value }.map { it.key to it.value }

    fun toJson(): String = JSONObject().apply {
        put("status", status.name)
        put("room_id", roomId)
        put("player_name", playerName)
        put("is_host", isHost)
        put("current_card_index", currentCardIndex)
        put("taken_count", takenCardIds.size)
        put("total_cards", totalCards)
        put("my_score", myScore())
        put("error_message", errorMessage)
    }.toString()
}
