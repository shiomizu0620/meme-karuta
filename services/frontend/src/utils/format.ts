// スコア表示や時間表示のフォーマッタ。

export const formatScore = (n: number) =>
  `${n.toLocaleString("ja-JP")}枚`;

export function formatElapsedSec(ms: number): string {
  const t = Math.floor(ms / 1000);
  const m = String(Math.floor(t / 60)).padStart(2, "0");
  return `${m}:${String(t % 60).padStart(2, "0")}`;
}

export interface RankedEntry { rank: number; name: string; score: number; }

export function rankPlayers(scores: Record<string, number>): RankedEntry[] {
  const sorted = Object.entries(scores).sort((a, b) => b[1] - a[1]);
  let rank = 0, prev = NaN;
  return sorted.map(([name, score], i) => {
    if (score !== prev) { rank = i + 1; prev = score; }
    return { rank, name, score };
  });
}
