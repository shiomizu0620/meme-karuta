# カードデータ

ミームカルタのマスターデータはこのディレクトリの YAML ファイルに記述されている。
コード（`generate.py` / `app.py`）には一切ハードコードしない。

## ディレクトリ構成

```
data/
└── cards/
    ├── basic.yaml      # 「基本セット」
    ├── sns.yaml        # 「SNSミーム」
    └── emotion.yaml    # 「感情ミーム」
```

1 ファイル＝1 セット。ファイル名はセット ID と一致させる規約（必須ではないが推奨）。

## カードを 1 枚追加する

1. 該当セットの YAML（例: `data/cards/basic.yaml`）の `cards:` 配列に 1 ブロック足す
   ```yaml
   - id: 31
     fuda: 完全に理解した
     yomi: わかった気になっているだけで実は何も理解していないとき
     image: kanzenni_rikai.jpg
     category: 反応
   ```
2. 画像ファイルを `services/frontend/public/images/` に置く（ファイル名は YAML の `image` と一致）
3. `docker compose restart card-gen` で反映

### ID のルール
- 正の整数、全ファイル横断でユニーク
- 既存カードの ID は変更しない（`pokedex` の収集記録が ID 参照のため）

### `image` のルール
- ファイル名のみ書く（`/images/` プレフィックスはローダーが付与）
- 拡張子は `jpg / jpeg / png / gif / webp`
- パス区切り（`/` や `\`）を含むとロードエラー

## 新しいセットを追加する

`data/cards/<set-id>.yaml` を新規作成して同じスキーマで書くだけ。`set.id` が他と
重複していなければ自動で取り込まれる。

## 検証

YAML 編集後、ロードが通るかは以下で確認できる：

```bash
docker compose run --rm card-gen python generate.py
# または
docker compose exec card-gen python generate.py
```

cards.json が再生成されエラーがなければ OK。
