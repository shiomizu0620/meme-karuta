# ネットミームカルタ

ネットミーム画像を札に使ったオンラインカルタ。最大8人がリアルタイムで対戦できる。

バックエンドは10言語のマイクロサービスに分割されており、各言語の実装行数を ±20% 以内に保つ運用ルールがある（詳細は[言語バランス](#言語バランス)を参照）。

---

## 構成

| 言語 | 役割 | サービス | ポート |
|------|------|---------|-------|
| TypeScript | フロントエンド (React + Vite) | `services/frontend` | 5173 |
| Go | API ゲートウェイ | `services/gateway` | 8080 |
| Elixir | リアルタイム通信 (WebSocket) | `services/realtime` | 4000 |
| Rust | 先着判定 | `services/judge` | 5002 |
| Python | カードデータ配信 | `services/card-gen` | 5000 |
| Python | 図鑑（収集カード管理） | `services/pokedex` | 5005 |
| Haskell | シャッフル (Fisher-Yates) | `services/shuffle` | 5001 |
| Scala | イベントキュー | `services/queue` | 5003 |
| C | バイナリシリアライザ | `services/serializer` | 5004 |
| Ruby | 運用タスク (Rake) | `services/tasks` | - |
| Kotlin | Android クライアント（予定） | `services/android` | - |

### 通信フロー

```
ブラウザ ─ HTTP ─► gateway (Go) ─┬─► card-gen   (Python)
                                 ├─► shuffle    (Haskell)
                                 ├─► judge      (Rust)
                                 ├─► queue      (Scala)
                                 ├─► serializer (C)
                                 └─► pokedex    (Python)

ブラウザ ─ WebSocket ─► realtime (Elixir)
                          └─ ルーム管理・全員への配信
```

---

## 必要環境

- Docker / Docker Compose v2
- Git
- （バランス確認のみ）Python 3.10+

---

## セットアップ

```bash
git clone https://github.com/shiomizu0620/meme-karuta.git
cd meme-karuta
```

ミーム画像は著作権の都合でリポジトリに含まれていないため、手元で `services/frontend/public/images/` 配下に配置する。ファイル名はカードデータ（[カードデータ管理](#カードデータ管理)参照）の `image` フィールドと一致させる。

```bash
docker compose up --build
```

| URL | 用途 |
|-----|------|
| http://localhost:5173 | フロントエンド |
| http://localhost:8080 | API ゲートウェイ |
| http://localhost:8080/api/routes | 利用可能な API 一覧 |
| http://localhost:8080/health | ヘルスチェック |
| http://localhost:8080/metrics | メトリクス |
| ws://localhost:4000/ws | リアルタイム通信 |

特定サービスだけ再ビルドしたいとき:

```bash
docker compose up --build frontend gateway
```

---

## API エンドポイント

ゲートウェイ経由でアクセスする。直接サービスを叩く必要は通常ない。

| パス | 上流 | 内容 |
|------|------|------|
| `GET /api/cards` | card-gen | カードデータ・セット一覧 |
| `POST /api/shuffle` | shuffle | カード ID 配列のシャッフル |
| `POST /api/judge` | judge | 先着判定（タップ順序の確定） |
| `POST /api/queue` | queue | ゲームイベントの記録 |
| `POST /api/serial` | serializer | カードデータのバイナリ変換 |
| `* /api/pokedex/...` | pokedex | プレイヤーごとの収集カード管理 |
| `GET /api/errors` | gateway | エラーコード一覧 |
| `GET /api/routes` | gateway | 本テーブルの自己記述 JSON |

---

## カードデータ管理

カードは `services/card-gen/data/cards/*.yaml` にセット単位で保存する。コードへのハードコードはしない。

```yaml
# services/card-gen/data/cards/basic.yaml
set:
  id: basic
  name: 基本セット
  description: 定番のネットミーム10枚
cards:
  - id: 1
    fuda: そうはならんやろ
    yomi: 誰がどう見てもそうなるのに本人だけ気づいていないとき
    image: souhanarannyaro.jpg   # /images/ プレフィックスは loader が付与
    category: 反応
```

追加手順:

1. 該当 YAML の `cards:` に追記（`id` は全 YAML 横断でユニーク）
2. 画像を `services/frontend/public/images/` に配置
3. `docker compose restart card-gen`

詳細は `services/card-gen/data/README.md` を参照。

---

## ゲーム仕様

### ルーム
- 定員: 2〜8 人
- ホストがゲーム開始前にカードセット・終了条件・読み手モードを設定する

### 読み手モード
| モード | 挙動 |
|-------|------|
| AI | `SpeechSynthesis` で自動読み上げ。誰でも「次へ」を押せる |
| プレイヤー指名 | 指名された読み手にだけ読み文が表示される。読み手のみ「次へ」を押せる |

### 終了条件
- 枚数モード: 指定枚数を取り終えたら終了
- 時間モード: 制限時間で強制終了

### 取り札
- 全員の画面に絵札を表示
- タップ順は `judge` (Rust) が確定する
- 確定結果は `realtime` (Elixir) 経由で全員に同報
- ゲーム終了後、取った札はコレクションとして 3D フリップで表裏が見られる

---

## 開発

### 個別サービスのログを追う

```bash
docker compose logs -f gateway realtime
```

### 運用タスク（Ruby）

`tasks` サービスは `profiles: tools` で常駐起動しない。実行するときだけ:

```bash
docker compose run --rm tasks rake -T
```

### 言語バランス

機能追加・修正のたびに以下を実行し、最大差が 20% を超えていないか確認する。

```bash
python check_balance.py
```

⚠️ が出たサービスには「意味のある処理」を追加して埋める。コメントや空行での水増しは禁止（バリデーション・エラーハンドリング・ログ・テストなどで埋める）。

---

## ディレクトリ

```
meme-karuta/
├── docker-compose.yml
├── check_balance.py
├── services/
│   ├── frontend/      # TypeScript (React + Vite)
│   ├── gateway/       # Go
│   ├── realtime/      # Elixir
│   ├── judge/         # Rust
│   ├── card-gen/      # Python (カード配信)
│   ├── pokedex/       # Python (図鑑)
│   ├── shuffle/       # Haskell
│   ├── queue/         # Scala
│   ├── serializer/    # C
│   ├── tasks/         # Ruby
│   └── android/       # Kotlin (将来)
└── README.md
```

`services/frontend/public/images/` は `.gitignore` で除外されている。

---

## デプロイ（DigitalOcean 等）

```bash
apt update && apt install -y docker.io docker-compose-plugin

git clone https://github.com/shiomizu0620/meme-karuta.git
cd meme-karuta

# 画像を別途アップロード
scp -r ./images/ root@your-server:/root/meme-karuta/services/frontend/public/

docker compose up -d
```

本番では `VITE_GATEWAY_URL` / `VITE_REALTIME_URL` を実ホストに合わせて上書きする。
