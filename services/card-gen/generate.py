"""
カードデータの集約・バリデーション・JSON 出力。

カードデータは `data/cards/*.yaml` を loader.py 経由で読み込む。本モジュールは
バリデーション・検索・統計などの純粋ロジックを提供しつつ、CLI から実行されたときは
集約済みデータを `cards.json` に書き出すオフラインビルダーとして動く。
"""

import json
import os
import re
from typing import TypedDict

from loader import DEFAULT_DATA_DIR, LoaderError, load_all

OUTPUT_PATH = os.path.join(os.path.dirname(__file__), "cards.json")


class CardDict(TypedDict):
    id: int
    fuda: str
    yomi: str
    image: str
    category: str
    set: str


# ---- 起動時データロード ----

CARDS: list[CardDict]
SETS: list[dict]

try:
    _loaded_cards, _loaded_sets = load_all(DEFAULT_DATA_DIR)
    CARDS = _loaded_cards  # type: ignore[assignment]
    SETS = [dict(s) for s in _loaded_sets]
except LoaderError as e:
    print(f"[FATAL] カードデータのロードに失敗: {e}")
    raise

SET_IDS = [s["id"] for s in SETS]
CATEGORIES = sorted(set(c["category"] for c in CARDS))


# ---- バリデーション ----

def validate_card(card: CardDict) -> list[str]:
    errors: list[str] = []
    if not isinstance(card.get("id"), int) or card["id"] <= 0:
        errors.append("id must be a positive integer")
    if not card.get("fuda") or not card["fuda"].strip():
        errors.append("fuda must not be empty")
    if not card.get("yomi") or not card["yomi"].strip():
        errors.append("yomi must not be empty")
    if not card.get("image") or not card["image"].strip():
        errors.append("image must not be empty")
    if card.get("image") and not re.match(r"^/images/[\w\-\.]+\.(jpg|jpeg|png|gif|webp)$", card["image"]):
        errors.append(f"image path format invalid: {card['image']}")
    if card.get("category") and card["category"] not in CATEGORIES:
        errors.append(f"unknown category: {card['category']}")
    if len(card.get("fuda", "")) > 64:
        errors.append("fuda too long (max 64)")
    if len(card.get("yomi", "")) > 256:
        errors.append("yomi too long (max 256)")
    return errors


def validate_all(cards: list[CardDict]) -> dict[int, list[str]]:
    results = {}
    ids_seen: set[int] = set()
    for card in cards:
        cid = card.get("id", -1)
        if cid in ids_seen:
            results.setdefault(cid, []).append(f"duplicate id: {cid}")
        ids_seen.add(cid)
        errs = validate_card(card)
        if errs:
            results[cid] = results.get(cid, []) + errs
    return results


# ---- 検索・フィルタ ----

def filter_by_category(cards: list[CardDict], category: str) -> list[CardDict]:
    return [c for c in cards if c.get("category") == category]


def filter_by_sets(cards: list[CardDict], set_ids: list[str]) -> list[CardDict]:
    if not set_ids:
        return cards
    return [c for c in cards if c.get("set") in set_ids]


def search_cards(cards: list[CardDict], query: str) -> list[CardDict]:
    q = query.lower()
    return [
        c for c in cards
        if q in c["fuda"].lower() or q in c["yomi"].lower()
    ]


def get_category_stats(cards: list[CardDict]) -> dict[str, int]:
    stats: dict[str, int] = {}
    for card in cards:
        cat = card.get("category", "uncategorized")
        stats[cat] = stats.get(cat, 0) + 1
    return dict(sorted(stats.items()))


def cards_by_id(cards: list[CardDict]) -> dict[int, CardDict]:
    return {c["id"]: c for c in cards}


# ---- 出力 ----

def generate(cards: list[CardDict] = CARDS, path: str = OUTPUT_PATH) -> None:
    errors = validate_all(cards)
    if errors:
        for card_id, errs in errors.items():
            for err in errs:
                print(f"[WARN] Card {card_id}: {err}")

    with open(path, "w", encoding="utf-8") as f:
        json.dump(cards, f, ensure_ascii=False, indent=2)

    stats = get_category_stats(cards)
    print(f"Generated {len(cards)} cards -> {path}")
    print(f"Categories: {stats}")
    if errors:
        print(f"Warnings: {sum(len(e) for e in errors.values())} issue(s)")


def export_categories_json(path: str | None = None) -> str:
    data = {
        "categories": CATEGORIES,
        "stats": get_category_stats(CARDS),
        "total": len(CARDS),
    }
    result = json.dumps(data, ensure_ascii=False, indent=2)
    if path:
        with open(path, "w", encoding="utf-8") as f:
            f.write(result)
    return result


# ---- 外部ファイルからの読み込み（プライベートデッキ等の上書き用） ----

def load_cards_from_file(path: str) -> list[CardDict]:
    """外部 JSON ファイルからカードリストを読み込む。形式エラーは例外を投げる。"""
    if not os.path.isfile(path):
        raise FileNotFoundError(f"cards file not found: {path}")
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, list):
        raise ValueError("cards JSON must be a list")
    for entry in data:
        if not isinstance(entry, dict):
            raise ValueError(f"each card must be an object, got: {type(entry).__name__}")
    return data  # type: ignore[return-value]


def merge_cards(base: list[CardDict], extra: list[CardDict]) -> list[CardDict]:
    """id をキーに既存 base に extra をマージ。extra 側が優先。"""
    by_id: dict[int, CardDict] = {c["id"]: dict(c) for c in base}  # type: ignore[misc]
    for c in extra:
        cid = c.get("id")
        if isinstance(cid, int) and cid > 0:
            by_id[cid] = dict(c)  # type: ignore[arg-type]
    return [by_id[k] for k in sorted(by_id.keys())]


# ---- 監査ログ ----

AUDIT_LOG_PATH = os.path.join(os.path.dirname(__file__), "audit.log")


def audit_log(action: str, detail: str) -> None:
    """カードデータへの変更履歴を追記。"""
    try:
        from datetime import datetime, timezone
        ts = datetime.now(timezone.utc).isoformat()
        with open(AUDIT_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"{ts}\t{action}\t{detail}\n")
    except OSError:
        pass


# ---- 全文検索スコアリング ----

def score_card(card: CardDict, query: str) -> float:
    """fuda 一致を 2.0、yomi 一致を 1.0 として重み付け。複数語は AND。"""
    if not query:
        return 0.0
    terms = [t for t in re.split(r"\s+", query.lower()) if t]
    if not terms:
        return 0.0
    fuda_lower = card["fuda"].lower()
    yomi_lower = card["yomi"].lower()
    score = 0.0
    for t in terms:
        in_fuda = t in fuda_lower
        in_yomi = t in yomi_lower
        if not in_fuda and not in_yomi:
            return 0.0
        if in_fuda:
            score += 2.0
        if in_yomi:
            score += 1.0
    return score


def ranked_search(cards: list[CardDict], query: str, limit: int = 20) -> list[CardDict]:
    scored = [(score_card(c, query), c) for c in cards]
    scored = [(s, c) for s, c in scored if s > 0]
    scored.sort(key=lambda x: (-x[0], x[1]["id"]))
    return [c for _, c in scored[:limit]]


# ---- エントリーポイント ----

def main() -> None:
    cards: list[CardDict] = list(CARDS)
    extra_path = os.environ.get("CARDS_EXTRA_PATH")
    if extra_path:
        try:
            extra = load_cards_from_file(extra_path)
            cards = merge_cards(cards, extra)
            audit_log("merge", f"loaded {len(extra)} from {extra_path}")
        except (FileNotFoundError, ValueError) as e:
            print(f"[WARN] could not load extra cards: {e}")
    audit_log("generate", f"{len(cards)} cards from {DEFAULT_DATA_DIR}")
    generate(cards)


if __name__ == "__main__":
    if os.environ.get("CARD_GEN_MODE") == "test":
        import unittest
        from tests.test_generate import build_suite
        unittest.TextTestRunner(verbosity=2).run(build_suite())
    else:
        main()
