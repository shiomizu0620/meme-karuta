package com.memekaruta.android

import android.content.Context
import java.io.File
import java.io.IOException
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * オフライン時にも最後に取得した cards.json を表示できるようにするための
 * 簡易キャッシュ。WebView 配下でも、ネットワーク断時にカードリストだけは
 * 見えるようにするためのもの。
 *
 * 設計上の制約:
 *   - 暗号化は不要（公開データなので）
 *   - 容量制限を超えたら古いものから捨てる
 *   - スレッドセーフ（バックグラウンドの同期処理とフォアグラウンドの読み出しが並行する）
 */
class OfflineCache(
    private val context: Context,
    private val maxEntries: Int = 8,
    private val maxBytes: Long = 2L * 1024 * 1024,
) {

    private val lock = ReentrantReadWriteLock()
    private val cacheDir: File by lazy {
        File(context.cacheDir, "memekaruta-offline").apply { mkdirs() }
    }

    fun put(key: String, content: String) {
        lock.write {
            val file = File(cacheDir, sanitize(key))
            try {
                file.writeText(content, Charsets.UTF_8)
            } catch (e: IOException) {
                AnalyticsLogger.shared().log("offline_cache_write_failed", mapOf("error" to (e.message ?: "?")))
                return@write
            }
            enforceLimits()
        }
    }

    fun get(key: String): String? {
        return lock.read {
            val file = File(cacheDir, sanitize(key))
            if (!file.exists()) return@read null
            try {
                file.readText(Charsets.UTF_8)
            } catch (e: IOException) {
                AnalyticsLogger.shared().log("offline_cache_read_failed", mapOf("error" to (e.message ?: "?")))
                null
            }
        }
    }

    fun has(key: String): Boolean = lock.read {
        File(cacheDir, sanitize(key)).exists()
    }

    fun remove(key: String): Boolean = lock.write {
        File(cacheDir, sanitize(key)).delete()
    }

    fun clear() {
        lock.write {
            cacheDir.listFiles()?.forEach { it.delete() }
        }
    }

    fun stats(): CacheStats {
        return lock.read {
            val files = cacheDir.listFiles() ?: emptyArray()
            val totalBytes = files.sumOf { it.length() }
            CacheStats(
                entries = files.size,
                totalBytes = totalBytes,
                capacityBytes = maxBytes,
                capacityEntries = maxEntries,
            )
        }
    }

    private fun enforceLimits() {
        val files = cacheDir.listFiles()?.toMutableList() ?: return
        files.sortBy { it.lastModified() }

        while (files.size > maxEntries) {
            val oldest = files.removeAt(0)
            oldest.delete()
        }

        var total = files.sumOf { it.length() }
        while (total > maxBytes && files.isNotEmpty()) {
            val oldest = files.removeAt(0)
            total -= oldest.length()
            oldest.delete()
        }
    }

    private fun sanitize(key: String): String {
        return key.map { ch ->
            if (ch.isLetterOrDigit() || ch == '-' || ch == '_' || ch == '.') ch else '_'
        }.joinToString("")
    }

    data class CacheStats(
        val entries: Int,
        val totalBytes: Long,
        val capacityBytes: Long,
        val capacityEntries: Int,
    ) {
        fun fillRatio(): Double = if (capacityBytes == 0L) 0.0 else totalBytes.toDouble() / capacityBytes

        fun summary(): String = "entries=$entries/$capacityEntries bytes=$totalBytes/$capacityBytes"
    }

    companion object {
        @Volatile
        private var instance: OfflineCache? = null

        fun shared(context: Context): OfflineCache {
            return instance ?: synchronized(this) {
                instance ?: OfflineCache(context.applicationContext).also { instance = it }
            }
        }

        const val KEY_CARDS_JSON = "cards.json"
        const val KEY_LAST_ROOM = "last_room.json"
    }
}
