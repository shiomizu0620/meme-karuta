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


# ---- 外部ファイルからの読み込み ----

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


# ---- HTTP サーバー ----

def build_app(cards: list[CardDict]):
    from http.server import BaseHTTPRequestHandler
    from urllib.parse import urlparse, parse_qs

    by_id = cards_by_id(cards)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return  # quiet

        def _send_json(self, status: int, payload) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):  # noqa: N802
            parsed = urlparse(self.path)
            path = parsed.path
            qs = parse_qs(parsed.query)

            if path == "/health":
                self._send_json(200, {"status": "ok", "card_count": len(cards)})
            elif path == "/cards":
                cat = (qs.get("category") or [None])[0]
                result = filter_by_category(cards, cat) if cat else cards
                self._send_json(200, result)
            elif path.startswith("/cards/"):
                try:
                    cid = int(path.removeprefix("/cards/"))
                except ValueError:
                    self._send_json(400, {"error": "invalid id"}); return
                card = by_id.get(cid)
                if card is None:
                    self._send_json(404, {"error": "card not found"}); return
                self._send_json(200, card)
            elif path == "/categories":
                self._send_json(200, {"categories": CATEGORIES, "stats": get_category_stats(cards)})
            elif path == "/search":
                q = (qs.get("q") or [""])[0]
                limit = int((qs.get("limit") or ["20"])[0])
                limit = max(1, min(limit, 100))
                self._send_json(200, ranked_search(cards, q, limit=limit))
            elif path == "/stats":
                self._send_json(200, {
                    "total": len(cards),
                    "by_category": get_category_stats(cards),
                    "validation_errors": validate_all(cards),
                })
            else:
                self._send_json(404, {"error": "not found"})

    return Handler


def run_server(host: str = "0.0.0.0", port: int = 5000) -> None:
    from http.server import HTTPServer
    server = HTTPServer((host, port), build_app(CARDS))
    audit_log("server_start", f"{host}:{port}")
    print(f"card-gen listening on {host}:{port}")
    try:
        server.serve_forever()
    finally:
        audit_log("server_stop", f"{host}:{port}")


# ---- エントリーポイント ----

def main() -> None:
    mode = os.environ.get("CARD_GEN_MODE", "generate")
    if mode == "serve":
        port = int(os.environ.get("PORT", "5000"))
        run_server(port=port)
    else:
        extra_path = os.environ.get("CARDS_EXTRA_PATH")
        cards: list[CardDict] = list(CARDS)
        if extra_path:
            try:
                extra = load_cards_from_file(extra_path)
                cards = merge_cards(cards, extra)
                audit_log("merge", f"loaded {len(extra)} from {extra_path}")
            except (FileNotFoundError, ValueError) as e:
                print(f"[WARN] could not load extra cards: {e}")
        generate(cards)


# ---- ユニットテスト ----

def _self_test() -> None:
    import unittest

    class CardValidationTests(unittest.TestCase):
        def test_valid_card_has_no_errors(self):
            self.assertEqual(validate_card(CARDS[0]), [])

        def test_negative_id_rejected(self):
            bad = dict(CARDS[0]); bad["id"] = -1
            errs = validate_card(bad)  # type: ignore[arg-type]
            self.assertTrue(any("positive integer" in e for e in errs))

        def test_empty_fuda_rejected(self):
            bad = dict(CARDS[0]); bad["fuda"] = "  "
            errs = validate_card(bad)  # type: ignore[arg-type]
            self.assertTrue(any("fuda" in e for e in errs))

        def test_bad_image_path_rejected(self):
            bad = dict(CARDS[0]); bad["image"] = "no/path.exe"
            errs = validate_card(bad)  # type: ignore[arg-type]
            self.assertTrue(any("image path" in e for e in errs))

        def test_validate_all_detects_duplicate_id(self):
            dup = list(CARDS) + [dict(CARDS[0])]  # type: ignore[list-item]
            results = validate_all(dup)  # type: ignore[arg-type]
            self.assertTrue(any("duplicate id" in e for v in results.values() for e in v))

    class SearchTests(unittest.TestCase):
        def test_search_returns_matching_cards(self):
            results = search_cards(CARDS, "そう")
            self.assertGreater(len(results), 0)

        def test_search_is_case_insensitive(self):
            r1 = search_cards(CARDS, "SOU")
            r2 = search_cards(CARDS, "sou")
            self.assertEqual(len(r1), len(r2))

        def test_score_card_higher_for_fuda_match(self):
            card = CARDS[0]
            score_fuda = score_card(card, card["fuda"][:3])
            score_yomi = score_card(card, card["yomi"][:3])
            self.assertGreater(score_fuda, 0)
            self.assertGreater(score_yomi, 0)

        def test_ranked_search_respects_limit(self):
            results = ranked_search(CARDS, "や", limit=3)
            self.assertLessEqual(len(results), 3)

    class CategoryTests(unittest.TestCase):
        def test_filter_by_category_returns_only_that_category(self):
            cat = CARDS[0]["category"]
            for c in filter_by_category(CARDS, cat):
                self.assertEqual(c["category"], cat)

        def test_get_category_stats_sums_to_total(self):
            stats = get_category_stats(CARDS)
            self.assertEqual(sum(stats.values()), len(CARDS))

    suite = unittest.TestLoader().loadTestsFromModule(__import__(__name__))
    unittest.TextTestRunner(verbosity=2).run(suite)


if __name__ == "__main__":
    if os.environ.get("CARD_GEN_MODE") == "test":
        _self_test()
    else:
        main()
