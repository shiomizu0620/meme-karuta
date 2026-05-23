# ネットミームカルタ

インターネットミームの画像を使ったオンラインカルタ。複数人がリアルタイムで同時に遊べる。

---

## コンセプト

**「GitHubのLanguages欄を10言語で埋め尽くす」**

通常のWebアプリが2〜3言語で済むところを、わざわざ10言語のマイクロサービスに分割した技術の無駄遣いプロジェクト。GitHubリポジトリのLanguages欄に10色のバーが並ぶことが設計目標のひとつ。

各言語のコード行数を常に均等（±20%以内）に保つという縛りがあり、機能追加のたびに `check_balance.py` でバランスを確認する。

---

## 言語構成

| 言語 | 割合 | 役割 | サービス |
|------|------|------|---------|
| TypeScript | ~10% | フロントエンド（React + Vite） | `services/frontend` |
| Go | ~10% | APIゲートウェイ | `services/gateway` |
| Rust | ~10% | 先着判定ロジック | `services/judge` |
| Elixir | ~10% | リアルタイム通信（WebSocket） | `services/realtime` |
| Python | ~10% | カードデータ生成スクリプト | `services/card-gen` |
| Haskell | ~10% | シャッフルアルゴリズム | `services/shuffle` |
| Ruby | ~10% | デプロイ・タスクスクリプト | `services/tasks` |
| Kotlin | ~10% | Androidクライアント（将来用） | `services/android` |
| Scala | ~10% | イベントキュー処理 | `services/queue` |
| C | ~10% | バイナリシリアライザー | `services/serializer` |

---

## アーキテクチャ

```
ブラウザ
  │
  ├─ HTTP ──────────────────────────────────────────────────────────
  │                                                                  │
  ▼                                                                  │
gateway (Go) :8080                                                   │
  ├── /api/cards    ──→  card-gen (Python) :5000                    │
  ├── /api/shuffle  ──→  shuffle (Haskell) :5001                    │
  ├── /api/judge    ──→  judge (Rust) :5002                         │
  ├── /api/queue    ──→  queue (Scala) :5003                        │
  └── /api/serial   ──→  serializer (C) :5004                       │
                                                                     │
  └─ WebSocket ─────────────────────────────────────────────────────┘
       │
       ▼
  realtime (Elixir) :4000
       └── ルーム管理・全員への通知
```

---

## 遊び方

1. **ルーム作成** - ホストがルームを作成してルームIDを参加者に共有する（最大8人）
2. **ゲーム設定** - ホストがよみてモードと終了条件を選択する
   - よみてモード: AIが自動読み上げ or プレイヤーを指名
   - 終了条件: 枚数指定 or 制限時間
3. **ゲームスタート** - カードがシャッフルされ全員の画面に絵札が表示される
4. **取り札** - 読み文を聞いて対応する絵札をタップする。先着判定はRustが処理する
5. **終了** - 条件を満たしたらスコアが表示される。取ったカードは3Dフリップでコレクション表示

---

## ローカル起動

```bash
git clone https://github.com/shiomizu0620/meme-karuta.git
cd meme-karuta

# カード画像を手動で配置（著作権のある画像はリポジトリ外）
# services/frontend/public/images/ に .jpg/.png を配置

docker compose up
```

| URL | サービス |
|-----|---------|
| http://localhost:5173 | フロントエンド |
| http://localhost:8080 | APIゲートウェイ |
| ws://localhost:4000 | WebSocket（Elixir） |

---

## 技術の無駄遣いポイント

**そのカルタのためだけにRustを動かしている**
絵札のタップ先着判定をRustの専用サービスで処理する。ロック不要な並行処理が売りだが、カルタの「先取り」判定のためだけにRustプロセスが常駐している。

**HaskellでFisher-Yatesシャッフル**
カードを並び替えるだけのために純粋関数型言語を召喚。副作用のないシャッフルを実現したが、誰も副作用を気にしていない。

**ElixirでWebSocket**
OTPアクター・モデルによる並行ルーム管理。8人のカルタ対戦のために、電話交換機を制御するために作られた言語の力を借りている。

**Scalaでイベントキュー**
ゲームイベントのログ管理にScalaを採用。JVMを起動させてカルタのスコアを記録する。

**CでバイナリシリアライザI**
カードデータをバイナリ変換するCのサービス。JSONでいいのに手動でメモリを触る。

**10言語を均等に保つ縛り**
機能追加のたびに `python check_balance.py` を実行し、行数が偏ったら意味のある処理を追記してバランスを取り戻す。コメント水増しは禁止。

---

## 言語バランス確認

```bash
python check_balance.py
```

最大差が20%を超えると警告が出る。各言語150〜200行を目安に均等を保つ。
