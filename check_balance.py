#!/usr/bin/env python3
"""services/ 配下の各サービスのコードを言語ごとに集計し、バランスをレポートする。

デフォルトは「実装行数」基準。`--bytes` で GitHub Linguist と同じ「バイト数」基準に切り替え。
"""
from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

THRESHOLD_PERCENT = 20.0
BAR_MAX_WIDTH = 13
SERVICES_DIR = Path(__file__).resolve().parent / "services"
SELF_NAME = Path(__file__).name


@dataclass
class LangSpec:
    name: str
    extensions: tuple[str, ...]
    line_comment: tuple[str, ...] = ()
    block_comments: tuple[tuple[str, str], ...] = ()


LANGUAGES: list[LangSpec] = [
    LangSpec("TypeScript", (".ts", ".tsx"), ("//",), (("/*", "*/"),)),
    LangSpec("Go",         (".go",),         ("//",), (("/*", "*/"),)),
    LangSpec("Rust",       (".rs",),         ("//",), (("/*", "*/"),)),
    LangSpec("Elixir",     (".ex", ".exs"),  ("#",)),
    LangSpec("Python",     (".py",),         ("#",), (('"""', '"""'), ("'''", "'''"))),
    LangSpec("Haskell",    (".hs",),         ("--",), (("{-", "-}"),)),
    LangSpec("Ruby",       (".rb",),         ("#",), (("=begin", "=end"),)),
    LangSpec("Kotlin",     (".kt",),         ("//",), (("/*", "*/"),)),
    LangSpec("Scala",      (".scala",),      ("//",), (("/*", "*/"),)),
    LangSpec("C",          (".c", ".h"),     ("//",), (("/*", "*/"),)),
]

EXCLUDED_DIRS = {
    "node_modules", "target", "_build", ".stack-work", "__pycache__",
    "dist", "build", ".git", "deps", "vendor",
}


def count_lines(path: Path, spec: LangSpec) -> int:
    """空行・コメント行を除いた実装行数を返す。"""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 0

    count = 0
    in_block: tuple[str, str] | None = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue

        # ブロックコメント継続中
        if in_block is not None:
            end = in_block[1]
            idx = line.find(end)
            if idx >= 0:
                rest = line[idx + len(end):].strip()
                in_block = None
                if rest and not _is_only_comment(rest, spec):
                    count += 1
            continue

        # 行頭がブロックコメント開始か?
        started_block = False
        for start, end in spec.block_comments:
            if line.startswith(start):
                # 単一行で閉じている場合
                close_idx = line.find(end, len(start))
                if close_idx >= 0:
                    rest = line[close_idx + len(end):].strip()
                    if rest and not _is_only_comment(rest, spec):
                        count += 1
                else:
                    in_block = (start, end)
                started_block = True
                break
        if started_block:
            continue

        # 行コメント
        if any(line.startswith(lc) for lc in spec.line_comment):
            continue

        count += 1

    return count


def _is_only_comment(text: str, spec: LangSpec) -> bool:
    t = text.strip()
    if not t:
        return True
    return any(t.startswith(lc) for lc in spec.line_comment)


def count_bytes(path: Path, _spec: LangSpec) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def collect_counts(measure=count_lines) -> dict[str, int]:
    totals: dict[str, int] = {lang.name: 0 for lang in LANGUAGES}
    ext_map: dict[str, LangSpec] = {ext: lang for lang in LANGUAGES for ext in lang.extensions}

    if not SERVICES_DIR.exists():
        return totals

    for root, dirs, files in os.walk(SERVICES_DIR):
        dirs[:] = [d for d in dirs if d not in EXCLUDED_DIRS and not d.startswith(".")]
        for name in files:
            if name == SELF_NAME:
                continue
            ext = os.path.splitext(name)[1].lower()
            spec = ext_map.get(ext)
            if spec is None:
                continue
            totals[spec.name] += measure(Path(root) / name, spec)
    return totals


def render(totals: dict[str, int], unit: str = "行") -> int:
    bar = "=" * 40
    print(bar)
    print("  言語バランスチェック")
    print(bar)

    max_count = max(totals.values()) if totals else 0
    nonzero = [v for v in totals.values() if v > 0]
    total = sum(totals.values())

    flagged: list[str] = []
    if nonzero:
        lo, hi = min(nonzero), max(nonzero)
        diff_pct = (hi - lo) / lo * 100 if lo else 0.0
        # 平均から20%以上ズレている言語に⚠️
        avg = sum(nonzero) / len(nonzero)
        for name, count in totals.items():
            if count == 0:
                continue
            if abs(count - avg) / avg * 100 >= THRESHOLD_PERCENT:
                flagged.append(name)
    else:
        lo = hi = 0
        diff_pct = 0.0

    name_width = max(len(lang.name) for lang in LANGUAGES) + 1
    for lang in LANGUAGES:
        count = totals[lang.name]
        share = (count / total * 100) if total else 0.0
        bar_len = int(round(count / max_count * BAR_MAX_WIDTH)) if max_count else 0
        warn = "  ⚠️ 要調整" if lang.name in flagged else ""
        print(f"{(lang.name + ':').ljust(name_width)} {count:>6}{unit} {'█' * bar_len:<{BAR_MAX_WIDTH}} {share:>4.1f}%{warn}")

    print(bar)
    if nonzero:
        msg = f"最大差: {hi - lo}{unit} ({diff_pct:.1f}%)"
        if diff_pct >= THRESHOLD_PERCENT:
            msg += f" - 基準値{THRESHOLD_PERCENT:.0f}%を超えています"
        else:
            msg += f" - 基準値{THRESHOLD_PERCENT:.0f}%以内"
        print(msg)
    else:
        print("計測対象のコードがまだありません")
    print(bar)

    return 1 if diff_pct >= THRESHOLD_PERCENT else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="サービスごとのコード量を言語別に集計")
    parser.add_argument(
        "--bytes",
        action="store_true",
        help="GitHub Linguist と同じバイト数基準で集計（既定は実装行数）",
    )
    args = parser.parse_args()
    if args.bytes:
        return render(collect_counts(count_bytes), unit="B")
    return render(collect_counts(count_lines), unit="行")


if __name__ == "__main__":
    sys.exit(main())
