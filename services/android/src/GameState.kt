package com.example.memekaruta

import org.json.JSONArray
import org.json.JSONObject

data class Card(
    val id: Int,
    val fuda: String,
    val yomi: String,
    val image: String,
) {
    companion object {
        fun fromJson(obj: JSONObject) = Card(
            id    = obj.getInt("id"),
            fuda  = obj.getString("fuda"),
            yomi  = obj.getString("yomi"),
            image = obj.getString("image"),
        )
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("fuda", fuda)
        put("yomi", yomi)
        put("image", image)
    }
}

data class GameSettings(
    val yomiteMode: String = "ai",
    val yomiteName: String = "",
    val endMode: String = "count",
    val endValue: Int = 5,
) {
    companion object {
        fun fromJson(obj: JSONObject) = GameSettings(
            yomiteMode = obj.optString("yomite_mode", "ai"),
            yomiteName = obj.optString("yomite_name", ""),
            endMode    = obj.optString("end_mode", "count"),
            endValue   = obj.optInt("end_value", 5),
        )
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("yomite_mode", yomiteMode)
        put("yomite_name", yomiteName)
        put("end_mode", endMode)
        put("end_value", endValue)
    }
}

data class RoomInfo(
    val roomId: String = "",
    val players: List<String> = emptyList(),
    val isHost: Boolean = false,
    val playerName: String = "",
) {
    companion object {
        fun fromJson(obj: JSONObject, playerName: String = "", isHost: Boolean = false): RoomInfo {
            val players = mutableListOf<String>()
            if (obj.has("players")) {
                val arr = obj.getJSONArray("players")
                repeat(arr.length()) { players.add(arr.getString(it)) }
            }
            return RoomInfo(
                roomId     = obj.optString("room_id", ""),
                players    = players,
                isHost     = isHost,
                playerName = playerName,
            )
        }
    }
}

class GameState {
    enum class Status { IDLE, CONNECTING, WAITING, PLAYING, FINISHED, ERROR }

    var status: Status = Status.IDLE
    var roomId: String = ""
    var players: List<String> = emptyList()
    var playerName: String = ""
    var isHost: Boolean = false
    var cards: List<Card> = emptyList()
    var settings: GameSettings = GameSettings()
    var currentCard: Card? = null
    var currentCardIndex: Int = -1
    var takenCardIds: MutableSet<Int> = mutableSetOf()
    var scores: Map<String, Int> = emptyMap()
    var errorMessage: String = ""
    var lastEventTime: Long = System.currentTimeMillis()

    fun reset() {
        status        = Status.IDLE
        roomId        = ""
        players       = emptyList()
        playerName    = ""
        isHost        = false
        cards         = emptyList()
        settings      = GameSettings()
        currentCard   = null
        currentCardIndex = -1
        takenCardIds  = mutableSetOf()
        scores        = emptyMap()
        errorMessage  = ""
        lastEventTime = System.currentTimeMillis()
    }

    fun applyServerMessage(json: String) {
        runCatching {
            val obj = JSONObject(json)
            lastEventTime = System.currentTimeMillis()

            when (obj.getString("type")) {
                "room_created" -> {
                    roomId     = obj.optString("room_id", "")
                    playerName = obj.optString("player_name", "")
                    isHost     = true
                    players    = listOf(playerName)
                    status     = Status.WAITING
                }
                "room_joined" -> {
                    roomId     = obj.optString("room_id", "")
                    isHost     = false
                    status     = Status.WAITING
                    players    = parseStringArray(obj.optJSONArray("players"))
                }
                "player_joined" -> {
                    val name = obj.optString("player_name", "")
                    players = players + name
                }
                "player_left" -> {
                    val name = obj.optString("player_name", "")
                    players = players.filter { it != name }
                }
                "game_started" -> {
                    status   = Status.PLAYING
                    cards    = parseCards(obj.optJSONArray("cards"))
                    settings = GameSettings.fromJson(obj.optJSONObject("settings") ?: JSONObject())
                    players  = parseStringArray(obj.optJSONArray("players"))
                    scores   = players.associateWith { 0 }
                    takenCardIds = mutableSetOf()
                }
                "card_reading" -> {
                    val cardObj = obj.optJSONObject("card")
                    currentCard      = cardObj?.let { Card.fromJson(it) }
                    currentCardIndex = obj.optInt("index", -1)
                }
                "card_taken" -> {
                    val cardId = obj.optInt("card_id", -1)
                    if (cardId >= 0) takenCardIds.add(cardId)
                    val scoresObj = obj.optJSONObject("scores")
                    if (scoresObj != null) {
                        scores = scoresObj.keys().asSequence().associateWith { scoresObj.getInt(it) }
                    }
                }
                "game_over" -> {
                    status = Status.FINISHED
                    val scoresObj = obj.optJSONObject("scores")
                    if (scoresObj != null) {
                        scores = scoresObj.keys().asSequence().associateWith { scoresObj.getInt(it) }
                    }
                }
                "error" -> {
                    errorMessage = obj.optString("message", "Unknown error")
                    if (status == Status.CONNECTING) status = Status.ERROR
                }
            }
        }
    }

    fun myScore(): Int = scores[playerName] ?: 0

    fun remainingCount(): Int = cards.size - takenCardIds.size

    fun rankedPlayers(): List<Pair<String, Int>> =
        scores.entries.sortedByDescending { it.value }.map { it.key to it.value }

    fun isYomite(): Boolean =
        settings.yomiteMode == "ai" || settings.yomiteName == playerName

    fun toJson(): String = JSONObject().apply {
        put("status", status.name)
        put("room_id", roomId)
        put("player_name", playerName)
        put("is_host", isHost)
        put("current_card_index", currentCardIndex)
        put("taken_count", takenCardIds.size)
        put("total_cards", cards.size)
        put("my_score", myScore())
        put("error_message", errorMessage)
    }.toString()

    private fun parseStringArray(arr: JSONArray?): List<String> {
        arr ?: return emptyList()
        return (0 until arr.length()).map { arr.getString(it) }
    }

    private fun parseCards(arr: JSONArray?): List<Card> {
        arr ?: return emptyList()
        return (0 until arr.length()).mapNotNull {
            runCatching { Card.fromJson(arr.getJSONObject(it)) }.getOrNull()
        }
    }
}

object CardValidator {
    private val REQUIRED_KEYS = setOf("id", "fuda", "yomi", "image")

    fun validate(card: Card): List<String> = buildList {
        if (card.id <= 0)          add("id must be positive")
        if (card.fuda.isBlank())   add("fuda must not be blank")
        if (card.yomi.isBlank())   add("yomi must not be blank")
        if (card.image.isBlank())  add("image must not be blank")
        if (card.image.length > 256) add("image path too long")
    }

    fun isValid(card: Card): Boolean = validate(card).isEmpty()

    fun fromJsonSafe(obj: JSONObject): Result<Card> = runCatching {
        val missing = REQUIRED_KEYS.filter { !obj.has(it) }
        if (missing.isNotEmpty()) error("Missing keys: $missing")
        Card.fromJson(obj)
    }
}

object ScoreCalculator {
    data class FinalResult(
        val rank: Int,
        val playerName: String,
        val score: Int,
        val percentage: Double,
    )

    fun calculateResults(scores: Map<String, Int>): List<FinalResult> {
        val total = scores.values.sum().coerceAtLeast(1)
        return scores.entries
            .sortedByDescending { it.value }
            .mapIndexed { index, (name, score) ->
                FinalResult(
                    rank       = index + 1,
                    playerName = name,
                    score      = score,
                    percentage = score.toDouble() / total * 100.0,
                )
            }
    }

    fun winner(scores: Map<String, Int>): String? =
        scores.maxByOrNull { it.value }?.key

    fun isTie(scores: Map<String, Int>): Boolean {
        val max = scores.values.maxOrNull() ?: return false
        return scores.values.count { it == max } > 1
    }
}
