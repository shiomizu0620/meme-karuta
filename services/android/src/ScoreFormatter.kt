package com.memekaruta.android

import java.text.NumberFormat
import java.util.Locale

/**
 * スコア表示用のフォーマッタ。WebView 側でも整形できるが、ネイティブ通知や
 * ウィジェットなどで表示する際にも使うため Kotlin 側でも用意する。
 *
 * - 同点の扱い: 順位は「飛び番方式」(1, 2, 2, 4 ...)
 * - 0 枚プレイヤーも順位に含める（参加賞的に）
 * - 表示は 1 位を金 / 2 位を銀 / 3 位を銅で色分けする想定。色自体は呼び出し側で持つ
 */
object ScoreFormatter {

    data class Entry(val name: String, val score: Int)

    data class RankedEntry(
        val rank: Int,
        val name: String,
        val score: Int,
        val isTopThree: Boolean,
    ) {
        fun display(locale: Locale = Locale.JAPAN): String {
            val formatted = NumberFormat.getInstance(locale).format(score)
            return "${rank}位  $name  ${formatted}枚"
        }
    }

    fun rank(entries: List<Entry>): List<RankedEntry> {
        val sorted = entries.sortedByDescending { it.score }
        val result = mutableListOf<RankedEntry>()
        var currentRank = 0
        var prevScore = Int.MIN_VALUE
        sorted.forEachIndexed { index, entry ->
            if (entry.score != prevScore) {
                currentRank = index + 1
                prevScore = entry.score
            }
            result.add(
                RankedEntry(
                    rank = currentRank,
                    name = entry.name,
                    score = entry.score,
                    isTopThree = currentRank <= 3,
                )
            )
        }
        return result
    }

    fun renderLeaderboard(entries: List<Entry>, locale: Locale = Locale.JAPAN): String {
        val ranked = rank(entries)
        if (ranked.isEmpty()) return "(参加者なし)"
        return ranked.joinToString("\n") { it.display(locale) }
    }
}
