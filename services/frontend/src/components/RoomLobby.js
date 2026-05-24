import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import { useState } from "react";
const ROOM_ID_PATTERN = /^[A-Z0-9]{4,8}$/;
export function RoomLobby({ onEnter, onShowPokedex, savedPlayerName = "", loading = false, serverError = null }) {
    const [tab, setTab] = useState("create");
    const [playerName, setPlayerName] = useState(savedPlayerName);
    const [roomId, setRoomId] = useState("");
    const [validationError, setValidationError] = useState(null);
    const handleSubmit = (e) => {
        e.preventDefault();
        const name = playerName.trim();
        if (name.length < 1 || name.length > 12) {
            setValidationError("プレイヤー名は1〜12文字で入力してください");
            return;
        }
        if (tab === "join") {
            const id = roomId.trim().toUpperCase();
            if (!ROOM_ID_PATTERN.test(id)) {
                setValidationError("ルームIDは英数字4〜8文字で入力してください");
                return;
            }
            setValidationError(null);
            onEnter({ mode: "join", playerName: name, roomId: id });
            return;
        }
        setValidationError(null);
        onEnter({ mode: "create", playerName: name });
    };
    const error = validationError ?? serverError;
    return (_jsx("div", { className: "lobby", children: _jsxs("div", { className: "lobby__card", children: [_jsxs("div", { className: "lobby__title-row", children: [_jsx("h1", { className: "lobby__title", children: "\u30CD\u30C3\u30C8\u30DF\u30FC\u30E0\u30AB\u30EB\u30BF" }), _jsx("button", { type: "button", className: "lobby__pokedex-btn", onClick: onShowPokedex, title: "\u56F3\u9451\u3092\u898B\u308B", children: "\u56F3\u9451" })] }), _jsx("p", { className: "lobby__subtitle", children: "\u6700\u59278\u4EBA\u3067\u904A\u3079\u308B\u30EA\u30A2\u30EB\u30BF\u30A4\u30E0\u30AB\u30EB\u30BF" }), _jsxs("div", { className: "lobby__tabs", role: "tablist", children: [_jsx("button", { type: "button", role: "tab", "aria-selected": tab === "create", className: `lobby__tab ${tab === "create" ? "lobby__tab--active" : ""}`, onClick: () => setTab("create"), disabled: loading, children: "\u30EB\u30FC\u30E0\u3092\u4F5C\u308B" }), _jsx("button", { type: "button", role: "tab", "aria-selected": tab === "join", className: `lobby__tab ${tab === "join" ? "lobby__tab--active" : ""}`, onClick: () => setTab("join"), disabled: loading, children: "\u30EB\u30FC\u30E0\u306B\u53C2\u52A0" })] }), _jsxs("form", { className: "lobby__form", onSubmit: handleSubmit, children: [_jsxs("label", { className: "lobby__field", children: [_jsx("span", { children: "\u30D7\u30EC\u30A4\u30E4\u30FC\u540D" }), _jsx("input", { type: "text", value: playerName, onChange: (e) => setPlayerName(e.target.value), placeholder: "\u4F8B: \u305D\u3046\u306F\u306A\u3089\u3093\u3084\u308D\u592A\u90CE", maxLength: 12, autoFocus: true, disabled: loading })] }), tab === "join" && (_jsxs("label", { className: "lobby__field", children: [_jsx("span", { children: "\u30EB\u30FC\u30E0ID" }), _jsx("input", { type: "text", value: roomId, onChange: (e) => setRoomId(e.target.value.toUpperCase()), placeholder: "\u4F8B: ABCD12", maxLength: 8, disabled: loading })] })), error && _jsx("p", { className: "lobby__error", children: error }), _jsx("button", { type: "submit", className: "lobby__submit", disabled: loading, children: loading ? "接続中…" : tab === "create" ? "ルームを作成する" : "ルームに入る" })] }), _jsx("p", { className: "lobby__hint", children: tab === "create" ? "あなたがホストになり、ゲーム設定を決められます。" : "ホストから共有されたルームIDを入力してください。" })] }) }));
}
