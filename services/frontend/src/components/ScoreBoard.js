import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import { EfudaCard } from "./EfudaCard";
export function ScoreBoard({ room, onPlayAgain, onShowPokedex }) {
    const { game, playerName } = room;
    if (!game)
        return null;
    const { scores, cards, takenCardIds } = game;
    const ranking = Object.entries(scores).sort(([, a], [, b]) => b - a);
    const myScore = scores[playerName] ?? 0;
    const takenCards = cards.filter((c) => takenCardIds.has(c.id));
    return (_jsx("div", { className: "scoreboard", children: _jsxs("div", { className: "scoreboard__card", children: [_jsx("h2", { className: "scoreboard__title", children: "\u30B2\u30FC\u30E0\u7D42\u4E86\uFF01" }), _jsx("div", { className: "scoreboard__ranking", children: ranking.map(([name, score], idx) => (_jsxs("div", { className: `scoreboard__row ${name === playerName ? "scoreboard__row--me" : ""}`, children: [_jsx("span", { className: "scoreboard__rank", children: idx === 0 ? "🥇" : idx === 1 ? "🥈" : idx === 2 ? "🥉" : `${idx + 1}位` }), _jsx("span", { className: "scoreboard__name", children: name }), _jsxs("span", { className: "scoreboard__score", children: [score, " \u679A"] })] }, name))) }), _jsxs("p", { className: "scoreboard__my-score", children: ["\u3042\u306A\u305F\u306E\u53D6\u308A\u679A\u6570: ", _jsxs("strong", { children: [myScore, " \u679A"] })] }), takenCards.length > 0 && (_jsxs("div", { className: "scoreboard__collection", children: [_jsx("p", { className: "scoreboard__collection-title", children: "\u53D6\u308A\u672D\u30B3\u30EC\u30AF\u30B7\u30E7\u30F3\uFF08\u30BF\u30C3\u30D7\u3067\u8868\u88CF\u5207\u308A\u66FF\u3048\uFF09" }), _jsx("div", { className: "scoreboard__collection-grid", children: takenCards.map((card) => (_jsx(EfudaCard, { card: card, taken: true, takenBy: null, isMe: false, onClick: () => { }, collectionMode: true }, card.id))) })] })), _jsxs("div", { className: "scoreboard__actions", children: [_jsx("button", { type: "button", className: "scoreboard__pokedex-btn", onClick: onShowPokedex, children: "\u56F3\u9451\u3092\u898B\u308B" }), _jsx("button", { type: "button", className: "scoreboard__again-btn", onClick: onPlayAgain, children: "\u30ED\u30D3\u30FC\u306B\u623B\u308B" })] })] }) }));
}
