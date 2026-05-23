"""
図鑑サービス - SQLite でプレイヤーごとの収集カードを管理する HTTP API。
"""

import json
import os
import sqlite3
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any
from urllib.parse import urlparse

DB_PATH = os.environ.get("DB_PATH", "/data/pokedex.db")


def get_db() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS collected_cards (
            player_name TEXT    NOT NULL,
            card_id     INTEGER NOT NULL,
            collected_at TEXT   NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            PRIMARY KEY (player_name, card_id)
        )
    """)
    conn.commit()
    return conn


def collect_card(player_name: str, card_id: int) -> bool:
    """カードを収集済みに記録する。既存レコードはスキップ。"""
    if not player_name or not isinstance(card_id, int) or card_id <= 0:
        return False
    conn = get_db()
    try:
        conn.execute(
            "INSERT OR IGNORE INTO collected_cards (player_name, card_id) VALUES (?, ?)",
            (player_name, card_id),
        )
        conn.commit()
        return True
    finally:
        conn.close()


def get_collected(player_name: str) -> list[int]:
    """プレイヤーの収集済みカードIDリストを返す。"""
    conn = get_db()
    try:
        rows = conn.execute(
            "SELECT card_id FROM collected_cards WHERE player_name = ? ORDER BY card_id",
            (player_name,),
        ).fetchall()
        return [row[0] for row in rows]
    finally:
        conn.close()


def get_stats(player_name: str) -> dict:
    """プレイヤーの収集統計を返す。"""
    conn = get_db()
    try:
        count = conn.execute(
            "SELECT COUNT(*) FROM collected_cards WHERE player_name = ?",
            (player_name,),
        ).fetchone()[0]
        first = conn.execute(
            "SELECT collected_at FROM collected_cards WHERE player_name = ? ORDER BY collected_at LIMIT 1",
            (player_name,),
        ).fetchone()
        return {"player_name": player_name, "total": count, "first_collected_at": first[0] if first else None}
    finally:
        conn.close()


def get_all_players() -> list[str]:
    """収集記録のあるプレイヤー一覧を返す。"""
    conn = get_db()
    try:
        rows = conn.execute(
            "SELECT DISTINCT player_name FROM collected_cards ORDER BY player_name"
        ).fetchall()
        return [row[0] for row in rows]
    finally:
        conn.close()


class PokedexHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print(f"[pokedex] {self.address_string()} {fmt % args}")

    def do_OPTIONS(self):
        self.send_response(204)
        self._add_cors_headers()
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/health":
            self._json(200, {"status": "ok"})

        elif path.startswith("/player/"):
            player_name = path.removeprefix("/player/")
            if not player_name:
                self._json(400, {"error": "player_name required"})
                return
            card_ids = get_collected(player_name)
            stats = get_stats(player_name)
            self._json(200, {
                "player_name": player_name,
                "card_ids": card_ids,
                "total": stats["total"],
                "first_collected_at": stats["first_collected_at"],
            })

        elif path == "/players":
            players = get_all_players()
            self._json(200, {"players": players, "total": len(players)})

        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/collect":
            body = self._read_json_body()
            if body is None:
                self._json(400, {"error": "JSON body required"})
                return
            player_name = body.get("player_name", "")
            card_id = body.get("card_id")
            if not player_name or not isinstance(card_id, int):
                self._json(400, {"error": "player_name (string) and card_id (integer) required"})
                return
            ok = collect_card(player_name, card_id)
            if ok:
                self._json(200, {"ok": True, "player_name": player_name, "card_id": card_id})
            else:
                self._json(400, {"error": "invalid player_name or card_id"})

        else:
            self._json(404, {"error": "not found"})

    def _json(self, status: int, body: Any) -> None:
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self._add_cors_headers()
        self.end_headers()
        self.wfile.write(payload)

    def _add_cors_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
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


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5005))
    server = HTTPServer(("0.0.0.0", port), PokedexHandler)
    print(f"pokedex listening on :{port}  (db={DB_PATH})")
    server.serve_forever()
