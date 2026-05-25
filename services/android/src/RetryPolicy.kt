package com.memekaruta.android

import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random

/**
 * WebSocket 再接続や API リトライで使う指数バックオフ。
 *
 * - 試行回数を加味して待ち時間を増やす
 * - 上限を設けてあまりに長くならないようにする
 * - ジッターを足してサーバーへの再接続集中を回避する
 *
 * thundering herd 対策のため、ジッターはデフォルト ±20%。
 */
class RetryPolicy(
    private val baseDelayMs: Long = 500,
    private val maxDelayMs: Long = 30_000,
    private val maxAttempts: Int = 8,
    private val jitterRatio: Double = 0.2,
    private val random: Random = Random.Default,
) {

    fun nextDelayMs(attempt: Int): Long {
        if (attempt < 1) return baseDelayMs
        val raw = baseDelayMs * 2.0.pow(attempt - 1)
        val capped = min(raw.toLong(), maxDelayMs)
        return applyJitter(capped)
    }

    fun shouldRetry(attempt: Int, error: Throwable? = null): Boolean {
        if (attempt >= maxAttempts) return false
        if (error is FatalRetryError) return false
        return true
    }

    fun summarize(): String =
        "RetryPolicy(base=${baseDelayMs}ms, max=${maxDelayMs}ms, attempts=$maxAttempts)"

    private fun applyJitter(delay: Long): Long {
        if (jitterRatio <= 0.0) return delay
        val band = (delay * jitterRatio).toLong()
        val offset = random.nextLong(-band, band + 1)
        return (delay + offset).coerceAtLeast(0)
    }

    /** リトライしても無意味なエラー（認証失敗・プロトコル違反など）を示すマーカー。 */
    class FatalRetryError(message: String) : RuntimeException(message)
}
