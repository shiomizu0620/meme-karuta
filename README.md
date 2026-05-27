# ネットミームカルタ

ネットミーム画像を札に使ったオンライン対戦カルタ。最大 8 人がリアルタイムで遊べる。

**設計思想:** バックエンドを **10 言語** のマイクロサービスに分割し、GitHub の言語比を **各 10.0% ずつ完全に均等** に保つ運用ルールがある。詳しくは[言語バランス哲学](#言語バランス哲学)を参照。

```
TypeScript │ Go │ Elixir │ Rust │ Python │ Haskell │ Scala │ C │ Ruby │ Kotlin
    10.0%     10.0%   10.0%   10.0%   10.0%    10.0%     10.0%  10.0%  10.0%  10.0%
```

---

## 目次

- [構成](#構成)
- [クイックスタート](#クイックスタート)
- [API エンドポイント](#api-エンドポイント)
- [カードデータ管理](#カードデータ管理)
- [ゲーム仕様](#ゲーム仕様)
- [開発](#開発)
- [言語バランス哲学](#言語バランス哲学)
- [デプロイ](#デプロイ)
- [ディレクトリ構成](#ディレクトリ構成)

---

## 構成

| 言語 | 役割 | サービス | ポート |
|------|------|---------|-------|
| TypeScript | フロントエンド (React + Vite) | `services/frontend` | 5173 |
| Go | API ゲートウェイ・ルーティング | `services/gateway` | 8080 |
| Elixir | リアルタイム通信 (WebSocket) | `services/realtime` | 4000 |
| Rust | 先着判定 | `services/judge` | 5002 |
| Python | カードデータ配信 | `services/card-gen` | 5000 |
| Python | 図鑑（収集カード管理） | `services/pokedex` | 5005 |
| Haskell | シャッフル (Fisher-Yates) | `services/shuffle` | 5001 |
| Scala | イベントキュー | `services/queue` | 5003 |
| C | バイナリシリアライザ | `services/serializer` | 5004 |
| Ruby | 運用タスク (Rake) | `services/tasks` | - |
| Kotlin | Android クライアント (予定) | `services/android` | - |

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

## クイックスタート

### 必要環境

- Docker / Docker Compose v2
- Git
- (バランス確認のみ) Python 3.10+

### 起動

```bash
git clone https://github.com/shiomizu0620/meme-karuta.git
cd meme-karuta
docker compose up --build
```

ミーム画像は著作権の都合で**リポジトリに含まれていない**ため、手元で `services/frontend/public/images/` 配下に配置する。ファイル名はカードデータの `image` フィールドと一致させる。

### 起動後の URL

| URL | 用途 |
|-----|------|
| http://localhost:5173 | フロントエンド |
| http://localhost:8080 | API ゲートウェイ |
| http://localhost:8080/api/routes | 利用可能な API 一覧 (自己記述 JSON) |
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
| `POST /api/judge` | judge | 先着判定 (タップ順序の確定) |
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

### 追加手順

1. 該当 YAML の `cards:` に追記 (`id` は全 YAML 横断でユニーク)
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

- **枚数モード**: 指定枚数を取り終えたら終了
- **時間モード**: 制限時間で強制終了

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

### 運用タスク (Ruby)

`tasks` サービスは `profiles: tools` で常駐起動しない。実行するときだけ:

```bash
docker compose run --rm tasks rake -T          # タスク一覧
docker compose run --rm tasks rake health:check  # 全サービスのヘルスチェック
docker compose run --rm tasks rake deploy:production  # 本番デプロイ
```

### テスト

各サービスは独立したテストスイートを持つ:

```bash
# Python (card-gen)
docker compose run --rm card-gen python -m unittest discover -s tests

# Rust (judge)
docker compose run --rm judge cargo test

# Elixir (realtime)
docker compose run --rm realtime mix test
```

---

## 言語バランス哲学

このプロジェクトのもう一つの目的は **GitHub の言語比表示を 10 言語ピッタリ 10.0% ずつにする** こと。
新規実装・修正のたびに各言語のバイト数を均等化する運用を続けている。

### 確認方法

```bash
python check_balance.py
```

⚠️ が出たサービスには「**意味のある処理**」を追加して埋める。コメント水増しや空行での調整は禁止 — バリデーション・エラーハンドリング・ログ・テスト・新規モジュールなど、運用上の価値を伴う実装で埋める。

### バイト数とリポジトリ上の見え方

GitHub Linguist は**バイト数**で言語比を計算する (行数ではなく)。`check_balance.py` は行数指標で、Linguist が実際に集計する量と少しズレるので、リポジトリページの Languages バーが本物の指標になる。

GitHub のサイドバーは仕様上 **Top 6 言語 + Other** しか表示しないので、10 言語をすべて 10% に揃えると Languages バーは:

- **表示される 6 言語が各 10.0%**
- **Other 約 40.0%** (残り 4 言語が押し込まれる)

という形になる。全言語の内訳はリポジトリトップの Languages バーをクリックすると見られる。

### `.gitattributes` の運用

Linguist の集計対象から外している項目:

| パス                                | 設定                       | 理由 |
|-------------------------------------|----------------------------|------|
| `services/realtime/deps/**`         | `linguist-vendored=true`   | `mix deps.get` で取得した cowboy / cowlib などのライブラリ。本体コードではない |
| `services/frontend/src/styles.css`  | `linguist-detectable=false`| CSS は 10 言語の設計に含まれない。シンタックスハイライトは維持 |

新たな vendor 系コードを取り込んだり、設計外の言語を増やしてしまった場合は `.gitattributes` を更新して Linguist の集計から外す。

---

## デプロイ

DigitalOcean などの Docker が動くサーバーで:

```bash
apt update && apt install -y docker.io docker-compose-plugin

git clone https://github.com/shiomizu0620/meme-karuta.git
cd meme-karuta

# 著作権画像は別途アップロード
scp -r ./images/ root@your-server:/root/meme-karuta/services/frontend/public/

docker compose up -d
```

### 環境変数

本番では `.env` で以下を上書きする:

| 変数 | 用途 |
|------|------|
| `VITE_GATEWAY_URL` | フロントエンドが叩く API ゲートウェイ |
| `VITE_REALTIME_URL` | WebSocket の接続先 |

### nginx リバースプロキシ

`nginx/` 配下に nginx 設定があり、`docker compose --profile prod up -d` で起動する。

---

## ディレクトリ構成

```text
meme-karuta/
├── docker-compose.yml
├── check_balance.py          # 言語バランスの確認
├── .gitattributes            # Linguist 集計対象の調整
├── services/
│   ├── frontend/             # TypeScript (React + Vite)
│   ├── gateway/              # Go
│   ├── realtime/             # Elixir
│   ├── judge/                # Rust
│   ├── card-gen/             # Python (カード配信)
│   ├── pokedex/              # Python (図鑑)
│   ├── shuffle/              # Haskell
│   ├── queue/                # Scala
│   ├── serializer/           # C
│   ├── tasks/                # Ruby
│   └── android/              # Kotlin (将来)
├── nginx/                    # 本番用リバースプロキシ
└── README.md
```

`services/frontend/public/images/` は `.gitignore` で除外されている (著作権の都合)。
