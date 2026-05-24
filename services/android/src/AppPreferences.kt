package com.example.memekaruta

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * AppPreferences はアプリ全体で参照される永続設定（ユーザー名、最後に入ったルームID、
 * 通信先 URL、サウンド/振動設定、最近遊んだルーム履歴）を SharedPreferences で保持する。
 *
 * 同じ Application スコープで複数の Activity から触られるので、書き込みは apply() を使う。
 */
class AppPreferences private constructor(context: Context) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    var playerName: String
        get() = prefs.getString(KEY_PLAYER_NAME, "") ?: ""
        set(value) = prefs.edit().putString(KEY_PLAYER_NAME, value.trim()).apply()

    var lastRoomId: String
        get() = prefs.getString(KEY_LAST_ROOM_ID, "") ?: ""
        set(value) = prefs.edit().putString(KEY_LAST_ROOM_ID, value).apply()

    var gatewayUrl: String
        get() = prefs.getString(KEY_GATEWAY_URL, DEFAULT_GATEWAY_URL) ?: DEFAULT_GATEWAY_URL
        set(value) = prefs.edit().putString(KEY_GATEWAY_URL, value).apply()

    var realtimeUrl: String
        get() = prefs.getString(KEY_REALTIME_URL, DEFAULT_REALTIME_URL) ?: DEFAULT_REALTIME_URL
        set(value) = prefs.edit().putString(KEY_REALTIME_URL, value).apply()

    var soundEnabled: Boolean
        get() = prefs.getBoolean(KEY_SOUND_ENABLED, true)
        set(value) = prefs.edit().putBoolean(KEY_SOUND_ENABLED, value).apply()

    var vibrationEnabled: Boolean
        get() = prefs.getBoolean(KEY_VIBRATION_ENABLED, true)
        set(value) = prefs.edit().putBoolean(KEY_VIBRATION_ENABLED, value).apply()

    /** 直近に遊んだルームの履歴。最新が先頭。最大 [MAX_HISTORY] 件まで保持する。 */
    fun recentRooms(): List<RecentRoom> {
        val raw = prefs.getString(KEY_RECENT_ROOMS, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val obj = arr.optJSONObject(i) ?: return@mapNotNull null
                RecentRoom(
                    roomId = obj.optString("room_id"),
                    label  = obj.optString("label"),
                    joinedAt = obj.optLong("joined_at"),
                )
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    fun rememberRoom(roomId: String, label: String = "") {
        if (roomId.isBlank()) return
        val now = System.currentTimeMillis()
        val current = recentRooms().filterNot { it.roomId == roomId }
        val updated = (listOf(RecentRoom(roomId, label, now)) + current).take(MAX_HISTORY)
        val arr = JSONArray()
        updated.forEach { r ->
            arr.put(JSONObject().apply {
                put("room_id", r.roomId)
                put("label", r.label)
                put("joined_at", r.joinedAt)
            })
        }
        prefs.edit().putString(KEY_RECENT_ROOMS, arr.toString()).apply()
    }

    fun clearRecentRooms() {
        prefs.edit().remove(KEY_RECENT_ROOMS).apply()
    }

    /** 設定全体をひとまとめにダンプ（デバッグ画面用）。 */
    fun dump(): JSONObject = JSONObject().apply {
        put("player_name", playerName)
        put("last_room_id", lastRoomId)
        put("gateway_url", gatewayUrl)
        put("realtime_url", realtimeUrl)
        put("sound_enabled", soundEnabled)
        put("vibration_enabled", vibrationEnabled)
        put("recent_rooms_count", recentRooms().size)
    }

    fun resetAll() {
        prefs.edit().clear().apply()
    }

    data class RecentRoom(val roomId: String, val label: String, val joinedAt: Long)

    companion object {
        private const val PREFS_NAME           = "meme_karuta_prefs"
        private const val KEY_PLAYER_NAME      = "player_name"
        private const val KEY_LAST_ROOM_ID     = "last_room_id"
        private const val KEY_GATEWAY_URL      = "gateway_url"
        private const val KEY_REALTIME_URL     = "realtime_url"
        private const val KEY_SOUND_ENABLED    = "sound_enabled"
        private const val KEY_VIBRATION_ENABLED = "vibration_enabled"
        private const val KEY_RECENT_ROOMS     = "recent_rooms"

        private const val DEFAULT_GATEWAY_URL  = "http://10.0.2.2:8080"
        private const val DEFAULT_REALTIME_URL = "ws://10.0.2.2:4000/ws"

        private const val MAX_HISTORY = 10

        @Volatile
        private var instance: AppPreferences? = null

        fun get(context: Context): AppPreferences =
            instance ?: synchronized(this) {
                instance ?: AppPreferences(context).also { instance = it }
            }
    }
}
