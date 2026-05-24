package com.example.memekaruta

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentLinkedDeque

/**
 * AnalyticsLogger は端末ローカルに対戦履歴・操作イベントを JSONL として追記する。
 *
 * - クラウド送信はしない（プライバシ重視。送るかは UI 側で同意確認）
 * - 1 ファイルが [MAX_FILE_BYTES] を超えたらローテーション
 * - 直近 N 件のイベントはオンメモリにも保持し、デバッグ画面から即座に参照できる
 *
 * Application スコープでシングルトン運用。Activity から `track(...)` を呼ぶ。
 */
class AnalyticsLogger private constructor(context: Context) {

    private val baseDir: File = File(context.filesDir, "analytics").apply { mkdirs() }
    private val tag = "MemeKarutaAnalytics"
    private val recentEvents = ConcurrentLinkedDeque<JSONObject>()
    private val isoFmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US)

    @Synchronized
    fun track(eventName: String, props: Map<String, Any?> = emptyMap()) {
        val entry = JSONObject().apply {
            put("ts", isoFmt.format(Date()))
            put("event", eventName)
            put("props", JSONObject(props))
        }
        recentEvents.addLast(entry)
        while (recentEvents.size > MAX_RECENT_EVENTS) recentEvents.pollFirst()
        appendToFile(entry)
        Log.d(tag, "track $eventName ${props.keys}")
    }

    fun trackGameStarted(roomId: String, playerCount: Int, mode: String) {
        track("game_started", mapOf("room_id" to roomId, "players" to playerCount, "mode" to mode))
    }

    fun trackCardTaken(roomId: String, cardId: Int, wasMine: Boolean, responseMs: Long) {
        track("card_taken", mapOf(
            "room_id" to roomId,
            "card_id" to cardId,
            "mine"    to wasMine,
            "response_ms" to responseMs,
        ))
    }

    fun trackGameOver(roomId: String, durationSec: Long, myScore: Int, totalCards: Int) {
        track("game_over", mapOf(
            "room_id" to roomId,
            "duration_sec" to durationSec,
            "my_score" to myScore,
            "total_cards" to totalCards,
        ))
    }

    fun trackError(category: String, message: String) {
        track("error", mapOf("category" to category, "message" to message))
    }

    /** 直近 N 件のイベントを JSON 配列で返す（デバッグ画面用）。 */
    fun recent(): JSONArray = JSONArray(recentEvents.toList())

    @Synchronized
    fun clearAll() {
        recentEvents.clear()
        baseDir.listFiles()?.forEach { it.delete() }
    }

    /** 現在のログファイルパス（テスト・デバッグ用）。 */
    fun currentLogFile(): File = File(baseDir, "events.log")

    private fun appendToFile(entry: JSONObject) {
        val file = currentLogFile()
        try {
            if (file.exists() && file.length() > MAX_FILE_BYTES) rotate(file)
            FileOutputStream(file, true).use { out ->
                out.write((entry.toString() + "\n").toByteArray(Charsets.UTF_8))
            }
        } catch (e: Exception) {
            Log.w(tag, "appendToFile failed: ${e.message}")
        }
    }

    private fun rotate(file: File) {
        val ts   = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val dest = File(baseDir, "events-$ts.log")
        if (file.renameTo(dest)) {
            pruneOldFiles()
        } else {
            file.delete()
        }
    }

    private fun pruneOldFiles() {
        val archived = baseDir.listFiles { f -> f.name.startsWith("events-") } ?: return
        if (archived.size <= MAX_ARCHIVED_FILES) return
        archived.sortedBy { it.lastModified() }
            .take(archived.size - MAX_ARCHIVED_FILES)
            .forEach { it.delete() }
    }

    companion object {
        private const val MAX_FILE_BYTES = 512 * 1024L
        private const val MAX_ARCHIVED_FILES = 5
        private const val MAX_RECENT_EVENTS = 200

        @Volatile
        private var instance: AnalyticsLogger? = null

        fun get(context: Context): AnalyticsLogger =
            instance ?: synchronized(this) {
                instance ?: AnalyticsLogger(context).also { instance = it }
            }
    }
}
