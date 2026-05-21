"""
カードデータ生成スクリプト。
CARDS リストからJSON出力する。バリデーション・カテゴリ管理・検索機能付き。
"""

import json
import os
import re
from typing import TypedDict

OUTPUT_PATH = os.path.join(os.path.dirname(__file__), "cards.json")


class CardDict(TypedDict):
    id: int
    fuda: str
    yomi: str
    image: str
    category: str


# ---- カードデータ ----

CARDS: list[CardDict] = [
    {"id": 1,  "fuda": "そうはならんやろ",    "yomi": "誰がどう見てもそうなるのに本人だけ気づいていないとき",                     "image": "/images/souhanarannyaro.jpg",  "category": "反応"},
    {"id": 2,  "fuda": "やめろ",              "yomi": "見ているだけで胃が痛くなる展開が始まったとき",                           "image": "/images/yamero.jpg",           "category": "反応"},
    {"id": 3,  "fuda": "許せ",               "yomi": "自分のミスを棚に上げて被害者面しているとき",                             "image": "/images/yuruse.jpg",           "category": "反応"},
    {"id": 4,  "fuda": "は？",               "yomi": "予想の斜め上をいく意味不明な発言をされたとき",                           "image": "/images/ha.jpg",               "category": "反応"},
    {"id": 5,  "fuda": "わかる",             "yomi": "言語化できなかった感情をズバリ言い当てられたとき",                       "image": "/images/wakaru.jpg",           "category": "共感"},
    {"id": 6,  "fuda": "無理",               "yomi": "どう頑張っても回避できない状況に追い込まれたとき",                       "image": "/images/muri.jpg",             "category": "反応"},
    {"id": 7,  "fuda": "天才か",             "yomi": "誰も思いつかなかった発想でサラッと問題を解決したとき",                   "image": "/images/tensaika.jpg",         "category": "褒め"},
    {"id": 8,  "fuda": "草",                 "yomi": "笑いをこらえられない状況が突然発生したとき",                             "image": "/images/kusa.jpg",             "category": "笑い"},
    {"id": 9,  "fuda": "お前が言うな",        "yomi": "最もその発言をしてはいけない人物がその発言をしたとき",                   "image": "/images/omaegaiune.jpg",       "category": "ツッコミ"},
    {"id": 10, "fuda": "知らんがな",          "yomi": "自分には一切関係のない問題を押し付けられたとき",                         "image": "/images/shirangana.jpg",       "category": "ツッコミ"},
    {"id": 11, "fuda": "なんでやねん",        "yomi": "理由もなく突然理不尽なことが起きて困惑したとき",                         "image": "/images/nandeyanen.jpg",       "category": "ツッコミ"},
    {"id": 12, "fuda": "ほんこれ",            "yomi": "誰かの意見が自分の気持ちを完璧に代弁してくれたとき",                     "image": "/images/honkore.jpg",          "category": "共感"},
    {"id": 13, "fuda": "尊い",               "yomi": "圧倒的な可愛さや美しさに心が浄化される瞬間",                             "image": "/images/toutoi.jpg",           "category": "褒め"},
    {"id": 14, "fuda": "は？待って",          "yomi": "情報の処理が追いつかずフリーズしたとき",                                 "image": "/images/hamatte.jpg",          "category": "反応"},
    {"id": 15, "fuda": "終わった",            "yomi": "修正不可能なミスをしたと気づいた瞬間",                                   "image": "/images/owatta.jpg",           "category": "絶望"},
    {"id": 16, "fuda": "正論すぎる",          "yomi": "反論の余地がない事実を突きつけられて黙るしかないとき",                   "image": "/images/seironsugiru.jpg",     "category": "共感"},
    {"id": 17, "fuda": "ぴえん",              "yomi": "小さな悲しみや失望が重なって涙が出そうになるとき",                       "image": "/images/pien.jpg",             "category": "感情"},
    {"id": 18, "fuda": "エモい",              "yomi": "懐かしさや切なさが混ざった感情が突然込み上げてきたとき",                 "image": "/images/emoi.jpg",             "category": "感情"},
    {"id": 19, "fuda": "待って笑う",          "yomi": "笑ってはいけない場面で笑いが止まらなくなったとき",                       "image": "/images/mattewarau.jpg",       "category": "笑い"},
    {"id": 20, "fuda": "なんも言えねぇ",      "yomi": "あまりにも衝撃的な出来事に言葉を失ったとき",                             "image": "/images/nanmoienee.jpg",       "category": "絶望"},
    {"id": 21, "fuda": "ガチ恋",              "yomi": "ゲームのキャラや配信者に本気で心を奪われたとき",                         "image": "/images/gachikoi.jpg",         "category": "感情"},
    {"id": 22, "fuda": "それはそう",          "yomi": "当たり前すぎる事実を改めて確認されたとき",                               "image": "/images/sorehasou.jpg",        "category": "共感"},
    {"id": 23, "fuda": "もう無理かもしれん",  "yomi": "限界を超えた疲労感が全身に広がったとき",                                 "image": "/images/moumurikamo.jpg",      "category": "絶望"},
    {"id": 24, "fuda": "ありがとうございました", "yomi": "何かが完全に終わった瞬間に使う万能締めの言葉",                       "image": "/images/arigatougozaimashita.jpg", "category": "挨拶"},
    {"id": 25, "fuda": "やばい",              "yomi": "良い意味でも悪い意味でも感情が追いつかないとき",                         "image": "/images/yabai.jpg",            "category": "反応"},
    {"id": 26, "fuda": "分かりみ",            "yomi": "相手の言っていることに深く共鳴したとき",                                 "image": "/images/wakarimi.jpg",         "category": "共感"},
    {"id": 27, "fuda": "さすがやな",          "yomi": "予想通りの実力を見せてくれたときの素直な称賛",                           "image": "/images/sasugayana.jpg",       "category": "褒め"},
    {"id": 28, "fuda": "もしかして天才？",    "yomi": "普通では思いつかないような発想に出会ったとき",                           "image": "/images/moshikasite_tensai.jpg", "category": "褒め"},
    {"id": 29, "fuda": "それな",              "yomi": "相手の発言が自分の考えと完全に一致したとき",                             "image": "/images/sorena.jpg",           "category": "共感"},
    {"id": 30, "fuda": "お疲れ様でした",      "yomi": "激しい戦いや作業がようやく終わったとき",                                 "image": "/images/otsukaresama.jpg",     "category": "挨拶"},
]

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


if __name__ == "__main__":
    generate()
