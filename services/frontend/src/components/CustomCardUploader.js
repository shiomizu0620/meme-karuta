import { jsxs as _jsxs, jsx as _jsx } from "react/jsx-runtime";
import { useRef, useState } from "react";
import { compressImage } from "../utils/imageCompress";
const FUDA_MAX = 64;
const YOMI_MAX = 256;
export function CustomCardUploader({ cards, playerName, isHost, maxCards, onAdd, onRemove }) {
    const [fuda, setFuda] = useState("");
    const [yomi, setYomi] = useState("");
    const [preview, setPreview] = useState(null);
    const [busy, setBusy] = useState(false);
    const [err, setErr] = useState(null);
    const fileRef = useRef(null);
    const reachedLimit = cards.length >= maxCards;
    const handleFile = async (file) => {
        if (!file)
            return;
        setErr(null);
        setBusy(true);
        try {
            const dataUrl = await compressImage(file);
            setPreview(dataUrl);
        }
        catch (e) {
            setErr(e instanceof Error ? e.message : "画像の処理に失敗しました");
            setPreview(null);
        }
        finally {
            setBusy(false);
        }
    };
    const reset = () => {
        setFuda("");
        setYomi("");
        setPreview(null);
        setErr(null);
        if (fileRef.current)
            fileRef.current.value = "";
    };
    const submit = () => {
        const f = fuda.trim();
        const y = yomi.trim();
        if (!preview) {
            setErr("画像を選んでください");
            return;
        }
        if (f.length < 1 || f.length > FUDA_MAX) {
            setErr(`絵札名は1〜${FUDA_MAX}文字`);
            return;
        }
        if (y.length < 1 || y.length > YOMI_MAX) {
            setErr(`読み文は1〜${YOMI_MAX}文字`);
            return;
        }
        if (reachedLimit) {
            setErr(`このルームの上限(${maxCards}枚)に達しています`);
            return;
        }
        onAdd({ fuda: f, yomi: y, image: preview });
        reset();
    };
    const canRemove = (c) => isHost || c.uploaded_by === playerName;
    return (_jsxs("div", { className: "custom-cards", children: [_jsxs("p", { className: "custom-cards__title", children: ["\u30AB\u30B9\u30BF\u30E0\u672D ", _jsxs("span", { className: "custom-cards__count", children: [cards.length, "/", maxCards] })] }), _jsx("p", { className: "custom-cards__hint", children: "\u81EA\u5206\u306E\u30DF\u30FC\u30E0\u753B\u50CF\u3092\u305D\u306E\u5834\u3067\u672D\u306B\u3067\u304D\u307E\u3059\uFF08\u3053\u306E\u30EB\u30FC\u30E0\u9650\u5B9A\uFF09\u3002" }), cards.length > 0 && (_jsx("ul", { className: "custom-cards__list", children: cards.map((c) => (_jsxs("li", { className: "custom-cards__item", children: [_jsx("img", { src: c.image, alt: c.fuda, className: "custom-cards__thumb" }), _jsxs("div", { className: "custom-cards__meta", children: [_jsx("span", { className: "custom-cards__fuda", children: c.fuda }), _jsx("span", { className: "custom-cards__yomi", children: c.yomi }), c.uploaded_by && (_jsxs("span", { className: "custom-cards__uploader", children: ["by ", c.uploaded_by] }))] }), canRemove(c) && (_jsx("button", { type: "button", className: "custom-cards__remove", onClick: () => onRemove(c.id), children: "\u524A\u9664" }))] }, c.id))) })), !reachedLimit && (_jsxs("div", { className: "custom-cards__form", children: [_jsxs("label", { className: "custom-cards__file-label", children: [_jsx("input", { ref: fileRef, type: "file", accept: "image/*", disabled: busy, onChange: (e) => handleFile(e.target.files?.[0] ?? null) }), busy ? "圧縮中…" : preview ? "画像を選び直す" : "画像を選ぶ"] }), preview && (_jsx("img", { src: preview, alt: "\u30D7\u30EC\u30D3\u30E5\u30FC", className: "custom-cards__preview" })), _jsx("input", { type: "text", className: "custom-cards__input", placeholder: `絵札名 (${FUDA_MAX}文字以内)`, maxLength: FUDA_MAX, value: fuda, onChange: (e) => setFuda(e.target.value) }), _jsx("textarea", { className: "custom-cards__textarea", placeholder: `読み文 (${YOMI_MAX}文字以内)`, maxLength: YOMI_MAX, value: yomi, onChange: (e) => setYomi(e.target.value), rows: 2 }), err && _jsx("p", { className: "custom-cards__error", children: err }), _jsx("button", { type: "button", className: "custom-cards__add", onClick: submit, disabled: busy || !preview || !fuda.trim() || !yomi.trim(), children: "\u8FFD\u52A0" })] }))] }));
}
