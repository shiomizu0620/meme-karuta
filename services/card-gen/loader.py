"""
YAML カードデータローダー。

`data/cards/*.yaml` をスキャンして、各ファイルに記述されたセット定義とカードリストを
集約する。画像はファイル名のみ書く規約で、ローダーが `/images/` プレフィックスを付与する。
"""

from __future__ import annotations

import glob
import os
import re
from typing import TypedDict

import yaml


IMAGE_PREFIX = "/images/"
IMAGE_FILENAME_RE = re.compile(r"^[\w\-.]+\.(jpg|jpeg|png|gif|webp)$")

DEFAULT_DATA_DIR = os.path.join(os.path.dirname(__file__), "data")


class CardDict(TypedDict):
    id: int
    fuda: str
    yomi: str
    image: str
    category: str
    set: str


class SetDict(TypedDict):
    id: str
    name: str
    description: str


class LoaderError(ValueError):
    """致命的なロードエラー（重複 ID、スキーマ不正など）。"""


def _read_yaml(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise LoaderError(f"{path}: トップレベルはマップでなければなりません")
    return data


def _validate_image_filename(path_in_yaml: str, source: str, card_id: int) -> str:
    """YAML 内に書かれた image 値を検証して /images/ プレフィックス付きパスを返す。"""
    if not isinstance(path_in_yaml, str) or not path_in_yaml.strip():
        raise LoaderError(f"{source}: card id={card_id} の image が空です")
    fname = path_in_yaml.strip()
    if "/" in fname or "\\" in fname:
        raise LoaderError(
            f"{source}: card id={card_id} の image はファイル名のみで指定してください "
            f"(got: {fname!r})"
        )
    if not IMAGE_FILENAME_RE.match(fname):
        raise LoaderError(
            f"{source}: card id={card_id} の image 拡張子が無効です "
            f"(got: {fname!r}, 許可: jpg/jpeg/png/gif/webp)"
        )
    return IMAGE_PREFIX + fname


def _parse_set_block(block: object, source: str) -> SetDict:
    if not isinstance(block, dict):
        raise LoaderError(f"{source}: set ブロックはマップでなければなりません")
    set_id = block.get("id")
    name = block.get("name")
    description = block.get("description", "")
    if not isinstance(set_id, str) or not set_id.strip():
        raise LoaderError(f"{source}: set.id が空または文字列ではありません")
    if not isinstance(name, str) or not name.strip():
        raise LoaderError(f"{source}: set.name が空または文字列ではありません")
    if not isinstance(description, str):
        raise LoaderError(f"{source}: set.description は文字列でなければなりません")
    return {"id": set_id.strip(), "name": name.strip(), "description": description.strip()}


def _parse_card(raw: object, set_id: str, source: str) -> CardDict:
    if not isinstance(raw, dict):
        raise LoaderError(f"{source}: cards 配列の要素はマップでなければなりません")
    cid = raw.get("id")
    if not isinstance(cid, int) or cid <= 0:
        raise LoaderError(f"{source}: card id は正の整数でなければなりません (got: {cid!r})")

    fuda = raw.get("fuda")
    yomi = raw.get("yomi")
    category = raw.get("category", "")
    if not isinstance(fuda, str) or not fuda.strip():
        raise LoaderError(f"{source}: card id={cid} の fuda が空です")
    if not isinstance(yomi, str) or not yomi.strip():
        raise LoaderError(f"{source}: card id={cid} の yomi が空です")
    if not isinstance(category, str):
        raise LoaderError(f"{source}: card id={cid} の category は文字列でなければなりません")

    image_path = _validate_image_filename(raw.get("image", ""), source, cid)

    return {
        "id": cid,
        "fuda": fuda,
        "yomi": yomi,
        "image": image_path,
        "category": category,
        "set": set_id,
    }


def load_all(data_dir: str = DEFAULT_DATA_DIR) -> tuple[list[CardDict], list[SetDict]]:
    """`data_dir/cards/*.yaml` を全てロードして (cards, sets) を返す。

    - 重複 ID は LoaderError
    - 画像はファイル名のみ受け付けて `/images/` プレフィックスを付与
    - cards は id 昇順、sets はファイル名昇順
    """
    cards_dir = os.path.join(data_dir, "cards")
    if not os.path.isdir(cards_dir):
        raise LoaderError(f"cards ディレクトリが見つかりません: {cards_dir}")

    files = sorted(glob.glob(os.path.join(cards_dir, "*.yaml")))
    if not files:
        raise LoaderError(f"YAML ファイルが {cards_dir} に1つもありません")

    all_cards: list[CardDict] = []
    all_sets: list[SetDict] = []
    seen_ids: dict[int, str] = {}
    seen_set_ids: dict[str, str] = {}

    for path in files:
        rel = os.path.basename(path)
        data = _read_yaml(path)
        set_block = data.get("set")
        cards_block = data.get("cards")
        if set_block is None or cards_block is None:
            raise LoaderError(f"{rel}: 'set' と 'cards' キーが必要です")
        if not isinstance(cards_block, list):
            raise LoaderError(f"{rel}: 'cards' は配列でなければなりません")

        set_dict = _parse_set_block(set_block, rel)
        if set_dict["id"] in seen_set_ids:
            raise LoaderError(
                f"{rel}: set.id={set_dict['id']!r} は "
                f"{seen_set_ids[set_dict['id']]} と重複しています"
            )
        seen_set_ids[set_dict["id"]] = rel
        all_sets.append(set_dict)

        for raw in cards_block:
            card = _parse_card(raw, set_dict["id"], rel)
            if card["id"] in seen_ids:
                raise LoaderError(
                    f"{rel}: card id={card['id']} は "
                    f"{seen_ids[card['id']]} と重複しています"
                )
            seen_ids[card["id"]] = rel
            all_cards.append(card)

    all_cards.sort(key=lambda c: c["id"])
    return all_cards, all_sets
