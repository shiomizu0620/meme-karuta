import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import { useEffect, useState } from "react";
import { CUSTOM_CARD_MAX } from "../hooks/useGame";
import { CustomCardUploader } from "./CustomCardUploader";
const GATEWAY_URL = import.meta.env
    .VITE_GATEWAY_URL ?? "http://localhost:8080";
const DEFAULT_SET_ID = "basic";
export function WaitingRoom({ roomId, players, isHost, playerName, customCards, onLeave, onStartGame, onAddCustomCard, onRemoveCustomCard, errorMsg }) {
    const [copied, setCopied] = useState(false);
    const [yomiteMode, setYomiteMode] = useState("ai");
    const [yomiteName, setYomiteName] = useState(playerName);
    const [endMode, setEndMode] = useState("count");
    const [endValue, setEndValue] = useState(5);
    const [availableSets, setAvailableSets] = useState([]);
    const [selectedSet, setSelectedSet] = useState(DEFAULT_SET_ID);
    useEffect(() => {
        if (!isHost)
            return;
        fetch(`${GATEWAY_URL}/api/cards/sets`)
            .then((r) => r.json())
            .then((data) => {
            if (Array.isArray(data.sets))
                setAvailableSets(data.sets);
        })
            .catch(() => { });
    }, [isHost]);
    const hasContent = selectedSet !== "" || customCards.length > 0;
    const copyRoomId = async () => {
        try {
            if (navigator.clipboard && window.isSecureContext) {
                await navigator.clipboard.writeText(roomId);
            } else {
                const ta = document.createElement("textarea");
                ta.value = roomId;
                ta.style.position = "fixed";
                ta.style.opacity = "0";
                document.body.appendChild(ta);
                ta.focus();
                ta.select();
                document.execCommand("copy");
                document.body.removeChild(ta);
            }
            setCopied(true);
            setTimeout(() => setCopied(false), 2000);
        } catch {
            // copy failed silently
        }
    };
    const selectSet = (id) => setSelectedSet(id);
    const handleStart = () => {
        onStartGame({
            yomite_mode: yomiteMode,
            yomite_name: yomiteMode === "player" ? yomiteName : playerName,
            end_mode: endMode,
            end_value: endValue,
            selected_sets: [selectedSet],
        });
    };
    return (_jsx("div", { className: "waiting", children: _jsxs("div", { className: "waiting__card", children: [_jsx("p", { className: "waiting__label", children: "\u30EB\u30FC\u30E0ID" }), _jsxs("div", { className: "waiting__room-id-row", children: [_jsx("span", { className: "waiting__room-id", children: roomId }), _jsx("button", { type: "button", className: "waiting__copy-btn", onClick: copyRoomId, children: copied ? "コピーしました" : "コピー" })] }), isHost && _jsx("p", { className: "waiting__hint", children: "\u3053\u306EID\u3092\u53C2\u52A0\u8005\u306B\u5171\u6709\u3057\u3066\u304F\u3060\u3055\u3044" }), _jsxs("div", { className: "waiting__section", children: [_jsxs("p", { className: "waiting__section-title", children: ["\u53C2\u52A0\u8005 ", _jsxs("span", { className: "waiting__count", children: [players.length, "/8"] })] }), _jsx("ul", { className: "waiting__players", children: players.map((name) => (_jsx("li", { children: _jsxs("div", { className: "waiting__player", children: [_jsx("span", { className: "waiting__player-name", children: name }), name === playerName && _jsx("span", { className: "waiting__badge waiting__badge--you", children: "\u3042\u306A\u305F" }), isHost && name === playerName && _jsx("span", { className: "waiting__badge waiting__badge--host", children: "\u30DB\u30B9\u30C8" })] }) }, name))) })] }), _jsxs("div", { className: "waiting__section", children: [_jsx(CustomCardUploader, { cards: customCards, playerName: playerName, isHost: isHost, maxCards: CUSTOM_CARD_MAX, onAdd: onAddCustomCard, onRemove: onRemoveCustomCard }), errorMsg && _jsx("p", { className: "waiting__set-warn", children: errorMsg })] }), isHost ? (_jsxs("div", { className: "waiting__settings", children: [_jsx("p", { className: "waiting__section-title", children: "\u30B2\u30FC\u30E0\u8A2D\u5B9A" }), availableSets.length > 0 && (_jsxs("div", { className: "waiting__settings-field", children: [_jsx("span", { children: "\u30AB\u30FC\u30C9\u30BB\u30C3\u30C8" }), _jsx("div", { className: "waiting__set-list", children: availableSets.map((s) => (_jsxs("label", { className: `waiting__set-item ${selectedSet === s.id ? "waiting__set-item--selected" : ""}`, children: [_jsx("input", { type: "radio", name: "card-set", checked: selectedSet === s.id, onChange: () => selectSet(s.id) }), _jsx("span", { className: "waiting__set-name", children: s.name }), _jsx("span", { className: "waiting__set-desc", children: s.description })] }, s.id))) }), !hasContent && (_jsx("p", { className: "waiting__set-warn", children: "\u30BB\u30C3\u30C8\u307E\u305F\u306F\u30AB\u30B9\u30BF\u30E0\u672D\u30921\u679A\u4EE5\u4E0A\u7528\u610F\u3057\u3066\u304F\u3060\u3055\u3044" }))] })), _jsxs("label", { className: "waiting__settings-field", children: [_jsx("span", { children: "\u3088\u307F\u3066\u30E2\u30FC\u30C9" }), _jsxs("div", { className: "waiting__radio-group", children: [_jsxs("label", { className: "waiting__radio", children: [_jsx("input", { type: "radio", checked: yomiteMode === "ai", onChange: () => setYomiteMode("ai") }), "AI\u30E2\u30FC\u30C9\uFF08\u81EA\u52D5\u8AAD\u307F\u4E0A\u3052\uFF09"] }), _jsxs("label", { className: "waiting__radio", children: [_jsx("input", { type: "radio", checked: yomiteMode === "player", onChange: () => setYomiteMode("player") }), "\u30D7\u30EC\u30A4\u30E4\u30FC\u6307\u540D"] })] })] }), yomiteMode === "player" && (_jsxs("label", { className: "waiting__settings-field", children: [_jsx("span", { children: "\u3088\u307F\u3066\u3092\u9078\u3076" }), _jsx("select", { className: "waiting__select", value: yomiteName, onChange: (e) => setYomiteName(e.target.value), children: players.map((p) => (_jsx("option", { value: p, children: p }, p))) })] })), _jsxs("label", { className: "waiting__settings-field", children: [_jsx("span", { children: "\u7D42\u4E86\u6761\u4EF6" }), _jsxs("div", { className: "waiting__radio-group", children: [_jsxs("label", { className: "waiting__radio", children: [_jsx("input", { type: "radio", checked: endMode === "count", onChange: () => { setEndMode("count"); setEndValue(5); } }), "\u679A\u6570"] }), _jsxs("label", { className: "waiting__radio", children: [_jsx("input", { type: "radio", checked: endMode === "time", onChange: () => { setEndMode("time"); setEndValue(60); } }), "\u6642\u9593"] })] })] }), _jsxs("label", { className: "waiting__settings-field", children: [_jsx("span", { children: endMode === "count" ? "取る枚数" : "制限時間（秒）" }), _jsx("input", { type: "number", className: "waiting__number-input", min: endMode === "count" ? 1 : 10, max: endMode === "count" ? 10 : 300, value: endValue, onChange: (e) => setEndValue(Number(e.target.value)) })] }), players.length < 2 && _jsxs("p", { className: "waiting__set-warn", children: ["\u3042\u3068", 2 - players.length, "\u4EBA\u306E\u53C2\u52A0\u304C\u5FC5\u8981\u3067\u3059"] }), _jsx("button", { type: "button", className: "waiting__start-btn", onClick: handleStart, disabled: players.length < 2 || !hasContent, children: "\u30B2\u30FC\u30E0\u30B9\u30BF\u30FC\u30C8" })] })) : (_jsx("p", { className: "waiting__status", children: "\u30DB\u30B9\u30C8\u304C\u30B2\u30FC\u30E0\u3092\u958B\u59CB\u3059\u308B\u307E\u3067\u304A\u5F85\u3061\u304F\u3060\u3055\u3044" })), _jsx("button", { type: "button", className: "waiting__leave", onClick: onLeave, children: "\u9000\u51FA\u3059\u308B" })] }) }));
}
