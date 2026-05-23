"""
カード生成サービスの HTTP API サーバー（stdlib のみ使用）。
"""

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

from generate import (
    CARDS,
    CATEGORIES,
    SETS,
    filter_by_category,
    filter_by_sets,
    get_category_stats,
    search_cards,
    validate_card,
)

CARD_MAP: dict[int, dict] = {c["id"]: c for c in CARDS}


# ---- HTTPハンドラ ----

class CardHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print(f"[card-gen] {self.address_string()} {fmt % args}")

    # ---- CORS プリフライト ----

    def do_OPTIONS(self):
        self.send_response(204)
        self._add_cors_headers()
        self.end_headers()

    # ---- GET ルーティング ----

    def do_GET(self):
        parsed = urlparse(self.path)
        path   = parsed.path.rstrip("/")
        params = parse_qs(parsed.query)

        if path == "/health":
            self._json(200, {"status": "ok", "card_count": len(CARDS)})

        elif path == "/cards":
            self._handle_list_cards(params)

        elif path.startswith("/cards/"):
            self._handle_get_card(path)

        elif path == "/sets":
            self._json(200, {"sets": SETS})

        elif path == "/categories":
            self._json(200, {
                "categories": CATEGORIES,
                "stats":      get_category_stats(CARDS),
            })

        elif path.startswith("/categories/") and path.endswith("/cards"):
            cat = path.removeprefix("/categories/").removesuffix("/cards")
            self._handle_cards_by_category(cat)

        elif path == "/stats":
            self._handle_stats()

        else:
            self._json(404, {"error": "not found"})

    # ---- POST ルーティング ----

    def do_POST(self):
        parsed = urlparse(self.path)
        path   = parsed.path.rstrip("/")

        if path == "/cards/validate":
            self._handle_validate()
        else:
            self._json(404, {"error": "not found"})

    # ---- ルートハンドラ実装 ----

    def _handle_list_cards(self, params: dict[str, list[str]]) -> None:
        category  = _first(params, "category")
        query     = _first(params, "q")
        limit     = _first_int(params, "limit")
        offset    = _first_int(params, "offset", default=0)
        sets_param = _first(params, "sets")

        cards: list[dict] = list(CARDS)

        if sets_param:
            set_ids = [s.strip() for s in sets_param.split(",") if s.strip()]
            if set_ids:
                cards = filter_by_sets(cards, set_ids)  # type: ignore[arg-type]

        if category:
            if category not in CATEGORIES:
                self._json(400, {"error": f"Unknown category '{category}'. Valid: {CATEGORIES}"})
                return
            cards = filter_by_category(cards, category)

        if query:
            if len(query) > 100:
                self._json(400, {"error": "Query string too long (max 100)"})
                return
            cards = search_cards(cards, query)

        total  = len(cards)
        cards  = cards[offset:]
        if limit is not None:
            if not 1 <= limit <= 200:
                self._json(400, {"error": "limit must be 1-200"})
                return
            cards = cards[:limit]

        self._json(200, {
            "cards":  cards,
            "total":  total,
            "offset": offset,
            "limit":  limit,
        })

    def _handle_get_card(self, path: str) -> None:
        try:
            card_id = int(path.removeprefix("/cards/"))
        except ValueError:
            self._json(400, {"error": "card_id must be an integer"})
            return
        card = CARD_MAP.get(card_id)
        if not card:
            self._json(404, {"error": f"Card {card_id} not found"})
            return
        self._json(200, card)

    def _handle_cards_by_category(self, category: str) -> None:
        if category not in CATEGORIES:
            self._json(404, {"error": f"Unknown category: {category}"})
            return
        cards = filter_by_category(CARDS, category)
        self._json(200, {"category": category, "cards": cards, "total": len(cards)})

    def _handle_validate(self) -> None:
        body = self._read_json_body()
        if body is None:
            self._json(400, {"error": "Request body must be valid JSON"})
            return
        if not isinstance(body, dict):
            self._json(400, {"error": "Request body must be a JSON object"})
            return
        card = {
            "id":       body.get("id", 0),
            "fuda":     body.get("fuda", ""),
            "yomi":     body.get("yomi", ""),
            "image":    body.get("image", ""),
            "category": body.get("category", ""),
        }
        errors = validate_card(card)
        if errors:
            self._json(422, {"valid": False, "errors": errors})
        else:
            self._json(200, {"valid": True})

    def _handle_stats(self) -> None:
        cat_stats    = get_category_stats(CARDS)
        total        = len(CARDS)
        avg_yomi     = sum(len(c["yomi"]) for c in CARDS) / total if total else 0
        avg_fuda     = sum(len(c["fuda"]) for c in CARDS) / total if total else 0
        self._json(200, {
            "total_cards":        total,
            "total_categories":   len(CATEGORIES),
            "category_breakdown": cat_stats,
            "avg_yomi_length":    round(avg_yomi, 1),
            "avg_fuda_length":    round(avg_fuda, 1),
        })

    # ---- ユーティリティ ----

    def _json(self, status: int, body: Any) -> None:
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self._add_cors_headers()
        self.end_headers()
        self.wfile.write(payload)

    def _add_cors_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin",  "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _read_json_body(self) -> Any:
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return None
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None


# ---- ヘルパー関数 ----

def _first(params: dict[str, list[str]], key: str) -> str | None:
    vals = params.get(key)
    return vals[0] if vals else None


def _first_int(params: dict[str, list[str]], key: str, default: int | None = None) -> int | None:
    val = _first(params, key)
    if val is None:
        return default
    try:
        return int(val)
    except ValueError:
        return default


# ---- エントリポイント ----

if __name__ == "__main__":
    port   = int(os.environ.get("PORT", 5000))
    server = HTTPServer(("0.0.0.0", port), CardHandler)
    print(f"card-gen listening on :{port}  ({len(CARDS)} cards, {len(CATEGORIES)} categories)")
    server.serve_forever()
