"""
カードデータの統計・分析ユーティリティ。

generate.py で読み込まれた CARDS を入力に、集約済みの統計情報や
セット間の差分レポートを生成する。app.py の管理用エンドポイントから
呼び出される想定。
"""

from __future__ import annotations

from collections import Counter, defaultdict
from typing import Iterable

from generate import CARDS, SETS, CATEGORIES, CardDict


# ---- 基本集計 ----

def count_by_set(cards: Iterable[CardDict]) -> dict[str, int]:
    """セット ID -> カード枚数 の辞書を返す。"""
    counter: Counter[str] = Counter()
    for c in cards:
        counter[c["set"]] += 1
    return dict(counter)


def count_by_category(cards: Iterable[CardDict]) -> dict[str, int]:
    """カテゴリ -> カード枚数 の辞書を返す。"""
    counter: Counter[str] = Counter()
    for c in cards:
        counter[c["category"]] += 1
    return dict(counter)


def cross_tab(cards: Iterable[CardDict]) -> dict[str, dict[str, int]]:
    """セット × カテゴリ のクロス集計を返す。"""
    table: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for c in cards:
        table[c["set"]][c["category"]] += 1
    return {s: dict(cats) for s, cats in table.items()}


# ---- テキスト解析 ----

def text_length_stats(cards: Iterable[CardDict]) -> dict[str, dict[str, float]]:
    """fuda / yomi の文字数の min / max / avg を返す。"""
    fuda_lengths: list[int] = []
    yomi_lengths: list[int] = []
    for c in cards:
        fuda_lengths.append(len(c["fuda"]))
        yomi_lengths.append(len(c["yomi"]))
    return {
        "fuda": _length_summary(fuda_lengths),
        "yomi": _length_summary(yomi_lengths),
    }


def _length_summary(values: list[int]) -> dict[str, float]:
    if not values:
        return {"min": 0.0, "max": 0.0, "avg": 0.0, "count": 0.0}
    return {
        "min": float(min(values)),
        "max": float(max(values)),
        "avg": round(sum(values) / len(values), 2),
        "count": float(len(values)),
    }


def find_duplicates_by_field(cards: Iterable[CardDict], field: str) -> dict[str, list[int]]:
    """指定フィールドの値が重複しているカードの ID を集める。"""
    buckets: dict[str, list[int]] = defaultdict(list)
    for c in cards:
        value = str(c.get(field, "")).strip()
        if not value:
            continue
        buckets[value].append(c["id"])
    return {k: v for k, v in buckets.items() if len(v) > 1}


# ---- 偏り検出 ----

def category_balance(cards: Iterable[CardDict], threshold: float = 0.25) -> dict[str, object]:
    """カテゴリ分布の偏りを検出する。

    一番多いカテゴリと少ないカテゴリの差が threshold(=25%) を超えていれば
    `imbalanced=True` を返す。check_balance.py の言語版に近い思想。
    """
    counts = count_by_category(cards)
    if not counts:
        return {"imbalanced": False, "ratio": 0.0, "counts": {}}
    total = sum(counts.values())
    max_c = max(counts.values())
    min_c = min(counts.values())
    ratio = (max_c - min_c) / total if total else 0.0
    return {
        "imbalanced": ratio > threshold,
        "ratio": round(ratio, 4),
        "max_category": max(counts, key=counts.get),
        "min_category": min(counts, key=counts.get),
        "counts": counts,
    }


# ---- レポート生成 ----

def render_report(cards: Iterable[CardDict] = None) -> str:
    """人間向けのレポート文字列を返す。CLI で `python stats.py` した時に表示。"""
    cards_list = list(cards) if cards is not None else list(CARDS)
    lines: list[str] = []
    lines.append("=" * 40)
    lines.append("  カード統計レポート")
    lines.append("=" * 40)
    lines.append(f"総カード数: {len(cards_list)}")
    lines.append(f"セット数: {len(SETS)}")
    lines.append(f"カテゴリ数: {len(CATEGORIES)}")
    lines.append("")
    lines.append("-- セット別 --")
    for sid, count in sorted(count_by_set(cards_list).items()):
        lines.append(f"  {sid:12} {count:3}枚")
    lines.append("")
    lines.append("-- カテゴリ別 --")
    for cat, count in sorted(count_by_category(cards_list).items(), key=lambda x: -x[1]):
        lines.append(f"  {cat:10} {count:3}枚")
    lines.append("")
    length = text_length_stats(cards_list)
    lines.append("-- テキスト長 --")
    lines.append(f"  fuda: min={length['fuda']['min']:.0f} max={length['fuda']['max']:.0f} avg={length['fuda']['avg']}")
    lines.append(f"  yomi: min={length['yomi']['min']:.0f} max={length['yomi']['max']:.0f} avg={length['yomi']['avg']}")
    lines.append("")
    balance = category_balance(cards_list)
    flag = "⚠️" if balance["imbalanced"] else "OK"
    lines.append(f"カテゴリ均衡: {flag} (差分比 {balance['ratio']:.2%})")
    lines.append("=" * 40)
    return "\n".join(lines)


def export_csv(cards: Iterable[CardDict] = None) -> str:
    """カードを CSV テキスト形式で書き出す。"""
    cards_list = list(cards) if cards is not None else list(CARDS)
    rows = ["id,fuda,yomi,image,category,set"]
    keys = ("id", "fuda", "yomi", "image", "category", "set")
    for c in cards_list:
        rows.append(",".join(str(c.get(k, "")).replace(",", "，") for k in keys))
    return "\n".join(rows)


if __name__ == "__main__":
    print(render_report())
