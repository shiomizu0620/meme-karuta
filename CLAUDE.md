# ネットミームカルタ - Claude Code 指示書

## プロジェクト概要

ネットミームの漫画画像を使ったオンラインカルタアプリ。
複数人がリアルタイムで同時に遊べる。
**GitHubの言語割合を10言語で均等にすることが設計思想。**

---

## 技術構成

| 言語 | 役割 | サービス名 |
|------|------|-----------|
| TypeScript | フロントエンド（React + Vite） | `services/frontend` |
| Go | APIゲートウェイ | `services/gateway` |
| Rust | 先着判定ロジック | `services/judge` |
| Elixir | リアルタイム通信（WebSocket） | `services/realtime` |
| Python | カードデータ生成スクリプト | `services/card-gen` |
| Haskell | シャッフルアルゴリズム | `services/shuffle` |
| Ruby | デプロイ・タスクスクリプト | `services/tasks` |
| Kotlin | Android クライアント（将来用） | `services/android` |
| Scala | イベントキュー処理 | `services/queue` |
| C | バイナリシリアライザー | `services/serializer` |

---

## ディレクトリ構成

```
meme-karuta/
├── docker-compose.yml
├── .gitignore              # public/images/ を除外
├── README.md
└── services/
    ├── frontend/           # TypeScript / React + Vite
    │   ├── Dockerfile
    │   ├── package.json
    │   └── src/
    │       ├── App.tsx
    │       ├── components/
    │       │   ├── EfudaCard.tsx       # 絵札コンポーネント
    │       │   ├── YomiFuda.tsx        # 読み札コンポーネント
    │       │   ├── GameBoard.tsx       # ゲーム盤面
    │       │   ├── RoomLobby.tsx       # ルーム作成・参加
    │       │   └── ScoreBoard.tsx      # スコア表示
    │       ├── hooks/
    │       │   ├── useGame.ts          # ゲームロジック
    │       │   └── useSocket.ts        # WebSocket接続
    │       └── data/
    │           └── cards.ts            # カードデータ（画像パス+読み文）
    │
    ├── gateway/            # Go / APIゲートウェイ
    │   ├── Dockerfile
    │   ├── go.mod
    │   └── main.go         # ルーティング・各サービスへのプロキシ
    │
    ├── judge/              # Rust / 先着判定
    │   ├── Dockerfile
    │   ├── Cargo.toml
    │   └── src/
    │       └── main.rs     # 先着判定API（HTTPサーバー）
    │
    ├── realtime/           # Elixir / WebSocket
    │   ├── Dockerfile
    │   ├── mix.exs
    │   └── lib/
    │       └── realtime/
    │           ├── room.ex             # ルーム管理
    │           └── socket_handler.ex  # WebSocketハンドラ
    │
    ├── card-gen/           # Python / カードデータ生成
    │   ├── Dockerfile
    │   ├── requirements.txt
    │   └── generate.py     # cards.jsonを生成するスクリプト
    │
    ├── shuffle/            # Haskell / シャッフル
    │   ├── Dockerfile
    │   ├── shuffle.cabal
    │   └── src/
    │       └── Main.hs     # Fisher-Yatesシャッフル API
    │
    ├── tasks/              # Ruby / タスクスクリプト
    │   ├── Dockerfile
    │   ├── Gemfile
    │   └── Rakefile        # デプロイ・ヘルスチェックタスク
    │
    ├── android/            # Kotlin / Androidクライアント
    │   ├── build.gradle
    │   └── src/
    │       └── MainActivity.kt  # WebView or ネイティブUI
    │
    ├── queue/              # Scala / イベントキュー
    │   ├── Dockerfile
    │   ├── build.sbt
    │   └── src/
    │       └── main/scala/
    │           └── Queue.scala  # ゲームイベントのキュー処理
    │
    └── serializer/         # C / バイナリシリアライザー
        ├── Dockerfile
        ├── Makefile
        └── serializer.c    # カードデータのバイナリ変換
```

---

## 機能仕様

### ルーム設定
- 人数上限: 2〜8人
- カードセット: 誰でも自由に選択可能
- 終了条件: ゲーム開始前にホストが「枚数」または「時間」で設定

### 読む担当（よみて）設定
| モード | 挙動 |
|--------|------|
| AIモード | アプリが自動でSpeechSynthesisで読み上げ、一定時間後に次へ進む |
| プレイヤーモード | ルーム内で特定のプレイヤーをよみてに指名。よみてだけ読み文が見える |

- よみての決め方: ホストがゲーム開始前に「AIに任せる」か「プレイヤーを指名」か選択
- 「次の札を読む」ボタン:
  - プレイヤーモード: よみてのみ操作可能
  - AIモード: 誰かがボタンを押したら次へ（または自動で進む）

### 画面表示ルール
- 読み文: よみてのみ表示（AIモード時は非表示）
- 絵札: 全員に表示
- スコア: ゲーム終了後にまとめて表示（リアルタイム表示なし）

### ゲーム終了条件
- 枚数モード: 指定枚数を取り終えたら終了
- 時間モード: 制限時間が来たら強制終了・スコア集計

---

## ゲームフロー

```
1. ホストがルームを作成（ルームID発行）
2. 参加者がルームIDで入室（上限8人）
3. ホストがゲーム設定
   - よみてモード選択（AIモード or プレイヤー指名）
   - 終了条件設定（枚数 or 時間）
   - カードセット選択（誰でも可）
4. ホストがゲームスタート
   → card-gen(Python) でカード一覧取得
   → shuffle(Haskell) でシャッフル
   → realtime(Elixir) で全員に配信
5. 読み上げフェーズ
   [AIモード]
     → アプリが自動でSpeechSynthesisで読み上げ
     → 誰かが「次へ」ボタンを押したら次の札へ
   [プレイヤーモード]
     → よみての画面にだけ読み文が表示される
     → よみてが読み上げ後「次へ」ボタンを押す
6. 取り札フェーズ
   → 全員の画面に絵札が表示される
   → 誰かが絵札をタップ
   → judge(Rust) に先着判定リクエスト
   → 勝者をrealtime(Elixir)で全員に通知
   → 全員の画面から該当の札が消える
7. 終了条件に達したらゲーム終了
   → スコアをまとめて全員に表示
```

---

## サービス間通信

```
ブラウザ
  ↓ HTTP
gateway(Go) :8080
  ├── /api/cards    → card-gen(Python) :5000
  ├── /api/shuffle  → shuffle(Haskell) :5001
  ├── /api/judge    → judge(Rust) :5002
  ├── /api/queue    → queue(Scala) :5003
  └── /api/serial   → serializer(C) :5004

ブラウザ
  ↓ WebSocket
realtime(Elixir) :4000
  └── ルーム管理・全員への通知
```

---

## カードの表裏仕様

### 絵札・読み札の対応
| | 内容 | 誰が見る |
|--|------|--------|
| 読み札 | ミームのセリフ（読み文） | よみてだけ |
| 絵札 | ミームの画像（1枚） | 全員 |

### 取ったカードのフリップ表示
ポケポケのカードめくり風に、取った瞬間に3Dフリップアニメーションで表裏を見せる。

- **表面**: ミーム画像
- **裏面**: セリフ（読み文）+ ミーム名

実装: `framer-motion` の `rotateY` を使った3Dフリップ

```tsx
// EfudaCard.tsx でのフリップ実装イメージ
const [flipped, setFlipped] = useState(false);

// 表面
<motion.div animate={{ rotateY: flipped ? 180 : 0 }}>
  <img src={card.image} />
</motion.div>

// 裏面
<motion.div animate={{ rotateY: flipped ? 0 : -180 }}>
  <p>{card.yomi}</p>
  <p>{card.title}</p>
</motion.div>
```

取ったカードはゲーム終了後にコレクション形式で一覧表示し、タップするたびに表裏を切り替えられる。

---

## カードデータ形式

### 配信フォーマット（API レスポンス・cards.json）

```typescript
export interface Card {
  id: number;
  fuda: string;       // 絵札テキスト（ミーム名）
  yomi: string;       // 読み文
  image: string;      // 画像パス（例: /images/souhanarannyaro.jpg）
  category: string;   // カテゴリ（反応 / 共感 / ツッコミ etc）
  set: string;        // 所属セット ID (basic / sns / emotion ...)
}
```

### マスターデータ（編集対象）

カードデータは `services/card-gen/data/cards/*.yaml` に **セット単位の YAML** で保存。
`generate.py` / `app.py` にはハードコードしない。詳しい追加手順は
`services/card-gen/data/README.md` を参照。

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

カード追加の流れ:

1. 該当 YAML の `cards:` に 1 ブロック追加（ID は全ファイル横断でユニーク）
2. 画像を `services/frontend/public/images/` に置く
3. `docker compose restart card-gen`

---

## .gitignore

```
# 著作権のある画像は除外
services/frontend/public/images/

# 依存関係
node_modules/
target/
_build/
.stack-work/
__pycache__/
```

---

## docker-compose.yml の方針

- 全サービスを`docker compose up`一発で起動できるようにする
- 環境変数`VITE_GATEWAY_URL`と`VITE_REALTIME_URL`でフロントの接続先を切り替え
- ローカル: `localhost`、本番: DigitalOceanのIP

---

## GitHub言語割合を均等にするためのルール

### 基本方針
- 各サービスのコード行数を**常に均等な状態**に保つ（目安: 各150〜200行）
- `.gitattributes`での言語強制指定はしない（自然な認識にこだわる）
- コメント水増しはNG。必ず意味のある処理を追加して調整する

### 調整タイミング
- 機能を追加・修正したら必ず`python check_balance.py`を走らせる
- ⚠️が出たサービスは意味のある処理を追加して均等に戻す
- 一番多い言語と少ない言語の差が**20%以上**開いたら要調整

### 意味のある処理の追加例（調整時に使う）
- バリデーション強化
- エラーハンドリングの充実
- ログ出力の追加
- ユニットテストの追加

### check_balance.py 仕様

`services/` 配下の各サービスのコードをカウントして均等かレポートするスクリプト。

```
# 実行
python check_balance.py

# 出力例
========================================
  言語バランスチェック
========================================
TypeScript:  187行 ████████████ 11.2%
Go:          195行 ████████████ 11.7%
Rust:        201行 █████████████ 12.0%
Elixir:      178行 ███████████ 10.7%
Python:      165行 ██████████  9.9%  ⚠️ 要調整
Haskell:     190行 ████████████ 11.4%
Ruby:        183行 ████████████ 11.0%
Kotlin:      172行 ███████████ 10.3%
Scala:       188行 ████████████ 11.3%
C:           210行 █████████████ 12.6%  ⚠️ 要調整
========================================
最大差: 45行 (27.3%) - 基準値20%を超えています
========================================
```

#### check_balance.py の実装仕様
- カウント対象: 空行・コメント行を除いた実装行のみ
- 各言語の対象拡張子:
  - TypeScript: `.ts`, `.tsx`
  - Go: `.go`
  - Rust: `.rs`
  - Elixir: `.ex`, `.exs`
  - Python: `.py`
  - Haskell: `.hs`
  - Ruby: `.rb`
  - Kotlin: `.kt`
  - Scala: `.scala`
  - C: `.c`, `.h`
- 判定基準: 最大行数と最小行数の差が20%以上で⚠️
- check_balance.py自体はカウント対象外

---

## 実装優先順位

1. **フロントエンド（TypeScript）** - UI・カード表示・WebSocket接続
2. **リアルタイム通信（Elixir）** - ルーム管理・全員同期
3. **先着判定（Rust）** - 競合処理が一番のキモ
4. **APIゲートウェイ（Go）** - 各サービスへのルーティング
5. **カード生成（Python）** - cards.jsonを吐き出すだけでOK
6. **シャッフル（Haskell）** - Fisher-Yatesをそのまま実装
7. **イベントキュー（Scala）** - ゲームイベントのログ管理
8. **バイナリシリアライザー（C）** - カードデータの変換
9. **タスクスクリプト（Ruby）** - Rakefileでデプロイコマンド整備
10. **Androidクライアント（Kotlin）** - WebViewでも可

---

## デプロイ（DigitalOcean）

```bash
# サーバーセットアップ
apt update && apt install docker.io docker-compose -y

# リポジトリをクローン（画像は手動でアップロード）
git clone https://github.com/yourname/meme-karuta.git
cd meme-karuta

# 画像を手動でアップロード
scp -r ./public/images/ root@your-server:/meme-karuta/services/frontend/public/

# 起動
docker compose up -d
```
