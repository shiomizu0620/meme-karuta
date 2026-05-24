import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import { useEffect, useState } from "react";
const GATEWAY_URL = import.meta.env
    .VITE_GATEWAY_URL ?? "http://localhost:8080";
export function Pokedex({ playerName, onClose }) {
    const [allCards, setAllCards] = useState([]);
    const [collectedIds, setCollectedIds] = useState(new Set());
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState(null);
    useEffect(() => {
        const cardsPromise = fetch(`${GATEWAY_URL}/api/cards`).then((r) => r.json());
        const pokedexPromise = playerName
            ? fetch(`${GATEWAY_URL}/api/pokedex/player/${encodeURIComponent(playerName)}`).then((r) => r.json())
            : Promise.resolve({ card_ids: [] });
        Promise.all([cardsPromise, pokedexPromise])
            .then(([cardsData, pokedexData]) => {
            const cards = Array.isArray(cardsData)
                ? cardsData
                : (cardsData.cards ?? []);
            setAllCards(cards);
            setCollectedIds(new Set(pokedexData.card_ids ?? []));
        })
            .catch(() => setError("データの読み込みに失敗しました"))
            .finally(() => setLoading(false));
    }, [playerName]);
    const collected = allCards.filter((c) => collectedIds.has(c.id));
    const remaining = allCards.filter((c) => !collectedIds.has(c.id));
    return (_jsxs("div", { className: "pokedex", children: [_jsxs("div", { className: "pokedex__header", children: [_jsxs("div", { children: [_jsx("h2", { className: "pokedex__title", children: "\u56F3\u9451" }), _jsx("p", { className: "pokedex__player", children: playerName ? `${playerName} の収集記録` : "カード一覧" })] }), _jsxs("div", { className: "pokedex__meta", children: [_jsxs("span", { className: "pokedex__progress-text", children: [collectedIds.size, " ", _jsx("span", { className: "pokedex__progress-sep", children: "/" }), " ", allCards.length, " \u679A"] }), _jsx("button", { type: "button", className: "pokedex__close-btn", onClick: onClose, children: "\u9589\u3058\u308B" })] })] }), loading && _jsx("p", { className: "pokedex__loading", children: "\u8AAD\u307F\u8FBC\u307F\u4E2D\u2026" }), error && _jsx("p", { className: "pokedex__error", children: error }), !loading && !error && (_jsxs(_Fragment, { children: [_jsx("div", { className: "pokedex__progress-bar-wrap", children: _jsx("div", { className: "pokedex__progress-bar-fill", style: { width: allCards.length > 0 ? `${(collectedIds.size / allCards.length) * 100}%` : "0%" } }) }), collected.length > 0 && (_jsxs("section", { className: "pokedex__section", children: [_jsxs("p", { className: "pokedex__section-title", children: ["\u53CE\u96C6\u6E08\u307F (", collected.length, "\u679A)"] }), _jsx("div", { className: "pokedex__grid", children: collected.map((card) => (_jsxs("div", { className: "pokedex__card pokedex__card--collected", children: [_jsx("div", { className: "pokedex__img-wrap", children: _jsx("img", { src: card.image, alt: card.fuda, className: "pokedex__img", onError: (e) => { e.currentTarget.style.display = "none"; } }) }), _jsx("p", { className: "pokedex__card-name", children: card.fuda })] }, card.id))) })] })), remaining.length > 0 && (_jsxs("section", { className: "pokedex__section", children: [_jsxs("p", { className: "pokedex__section-title", children: ["\u672A\u53CE\u96C6 (", remaining.length, "\u679A)"] }), _jsx("div", { className: "pokedex__grid", children: remaining.map((card) => (_jsxs("div", { className: "pokedex__card pokedex__card--unknown", children: [_jsx("div", { className: "pokedex__img-wrap pokedex__img-wrap--unknown", children: _jsx("div", { className: "pokedex__silhouette" }) }), _jsx("p", { className: "pokedex__card-name pokedex__card-name--unknown", children: "???" })] }, card.id))) })] })), allCards.length === 0 && (_jsx("p", { className: "pokedex__empty", children: "\u30AB\u30FC\u30C9\u30C7\u30FC\u30BF\u304C\u898B\u3064\u304B\u308A\u307E\u305B\u3093\u3067\u3057\u305F" }))] }))] }));
}
