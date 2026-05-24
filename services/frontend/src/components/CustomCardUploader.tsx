import { useRef, useState } from "react";
import type { Card } from "../hooks/useGame";
import { compressImage } from "../utils/imageCompress";

type Props = {
  cards: Card[];
  playerName: string;
  isHost: boolean;
  maxCards: number;
  onAdd: (input: { fuda: string; yomi: string; image: string }) => void;
  onRemove: (id: number) => void;
};

const FUDA_MAX = 64;
const YOMI_MAX = 256;

export function CustomCardUploader({ cards, playerName, isHost, maxCards, onAdd, onRemove }: Props) {
  const [fuda, setFuda] = useState("");
  const [yomi, setYomi] = useState("");
  const [preview, setPreview] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement | null>(null);

  const reachedLimit = cards.length >= maxCards;

  const handleFile = async (file: File | null) => {
    if (!file) return;
    setErr(null);
    setBusy(true);
    try {
      const dataUrl = await compressImage(file);
      setPreview(dataUrl);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "画像の処理に失敗しました");
      setPreview(null);
    } finally {
      setBusy(false);
    }
  };

  const reset = () => {
    setFuda("");
    setYomi("");
    setPreview(null);
    setErr(null);
    if (fileRef.current) fileRef.current.value = "";
  };

  const submit = () => {
    const f = fuda.trim();
    const y = yomi.trim();
    if (!preview) { setErr("画像を選んでください"); return; }
    if (f.length < 1 || f.length > FUDA_MAX) { setErr(`絵札名は1〜${FUDA_MAX}文字`); return; }
    if (y.length < 1 || y.length > YOMI_MAX) { setErr(`読み文は1〜${YOMI_MAX}文字`); return; }
    if (reachedLimit) { setErr(`このルームの上限(${maxCards}枚)に達しています`); return; }
    onAdd({ fuda: f, yomi: y, image: preview });
    reset();
  };

  const canRemove = (c: Card) => isHost || c.uploaded_by === playerName;

  return (
    <div className="custom-cards">
      <p className="custom-cards__title">
        カスタム札 <span className="custom-cards__count">{cards.length}/{maxCards}</span>
      </p>
      <p className="custom-cards__hint">自分のミーム画像をその場で札にできます（このルーム限定）。</p>

      {cards.length > 0 && (
        <ul className="custom-cards__list">
          {cards.map((c) => (
            <li key={c.id} className="custom-cards__item">
              <img src={c.image} alt={c.fuda} className="custom-cards__thumb" />
              <div className="custom-cards__meta">
                <span className="custom-cards__fuda">{c.fuda}</span>
                <span className="custom-cards__yomi">{c.yomi}</span>
                {c.uploaded_by && (
                  <span className="custom-cards__uploader">by {c.uploaded_by}</span>
                )}
              </div>
              {canRemove(c) && (
                <button type="button" className="custom-cards__remove" onClick={() => onRemove(c.id)}>
                  削除
                </button>
              )}
            </li>
          ))}
        </ul>
      )}

      {!reachedLimit && (
        <div className="custom-cards__form">
          <label className="custom-cards__file-label">
            <input
              ref={fileRef}
              type="file"
              accept="image/*"
              disabled={busy}
              onChange={(e) => handleFile(e.target.files?.[0] ?? null)}
            />
            {busy ? "圧縮中…" : preview ? "画像を選び直す" : "画像を選ぶ"}
          </label>
          {preview && (
            <img src={preview} alt="プレビュー" className="custom-cards__preview" />
          )}
          <input
            type="text"
            className="custom-cards__input"
            placeholder={`絵札名 (${FUDA_MAX}文字以内)`}
            maxLength={FUDA_MAX}
            value={fuda}
            onChange={(e) => setFuda(e.target.value)}
          />
          <textarea
            className="custom-cards__textarea"
            placeholder={`読み文 (${YOMI_MAX}文字以内)`}
            maxLength={YOMI_MAX}
            value={yomi}
            onChange={(e) => setYomi(e.target.value)}
            rows={2}
          />
          {err && <p className="custom-cards__error">{err}</p>}
          <button
            type="button"
            className="custom-cards__add"
            onClick={submit}
            disabled={busy || !preview || !fuda.trim() || !yomi.trim()}
          >
            追加
          </button>
        </div>
      )}
    </div>
  );
}
