import { jsx as _jsx, Fragment as _Fragment, jsxs as _jsxs } from "react/jsx-runtime";
import { useMemo } from "react";
import { EfudaCard } from "./EfudaCard";
function shuffleForDisplay(cards) {
    let seed = cards.reduce((acc, c) => acc + c.id * 2654435761, 0) >>> 0;
    const rng = () => {
        seed = (seed * 1664525 + 1013904223) >>> 0;
        return seed / 0x100000000;
    };
    const arr = [...cards];
    for (let i = arr.length - 1; i > 0; i--) {
        const j = Math.floor(rng() * (i + 1));
        [arr[i], arr[j]] = [arr[j], arr[i]];
    }
    return arr;
}
export function GameBoard({ room, onTakeCard, onNextCard, onSpeakCard, isFouled, cardResolved }) {
    const { game, playerName, isHost } = room;
    const isAiMode = game?.settings.yomite_mode === "ai";
    const currentCard = game?.currentCard ?? null;
    const displayCards = useMemo(() => shuffleForDisplay(game?.cards ?? []), [game?.cards]);
    if (!game)
        return null;
    const { cards, settings, takenCardIds, scores } = game;
    const isYomite = isAiMode || settings.yomite_name === playerName;
    const remainingCards = displayCards.filter((c) => !takenCardIds.has(c.id));
    const takenCards = displayCards.filter((c) => takenCardIds.has(c.id));
    const totalTaken = takenCardIds.size;
    const totalCards = cards.length;
    return (_jsxs("div", { className: "board", children: [_jsxs("div", { className: "board__reading", children: [_jsx("div", { className: "board__reading-inner", children: currentCard ? (_jsx(_Fragment, { children: isYomite && !isAiMode ? (_jsxs(_Fragment, { children: [_jsx("p", { className: "board__yomi", children: currentCard.yomi }), _jsx("p", { className: "board__fuda-hint", children: currentCard.fuda })] })) : isAiMode && isHost ? (_jsx("button", { type: "button", className: "board__speak-btn", onClick: onSpeakCard, children: "\uD83D\uDD0A \u8AAD\u307F\u4E0A\u3052\u308B" })) : isAiMode ? (_jsx("p", { className: "board__yomi board__yomi--hidden", children: "\u30DB\u30B9\u30C8\u306E\u8AAD\u307F\u4E0A\u3052\u3092\u5F85\u3063\u3066\u3044\u307E\u3059\u2026" })) : (_jsx("p", { className: "board__yomi board__yomi--hidden", children: "\u3088\u307F\u3066\u304C\u8AAD\u307F\u4E0A\u3052\u4E2D\u2026" })) })) : (_jsx("p", { className: "board__yomi board__yomi--hidden", children: "\u6E96\u5099\u4E2D\u2026" })) }), isYomite && (_jsx("button", { type: "button", className: "board__next-btn", onClick: onNextCard, disabled: !cardResolved, children: "\u6B21\u306E\u672D\u3078 \u2192" }))] }), _jsxs("div", { className: "board__progress-row", children: [_jsxs("span", { className: "board__progress-text", children: ["\u6B8B\u308A ", remainingCards.length, " / ", totalCards, " \u679A"] }), _jsx("div", { className: "board__progress-bar", children: _jsx("div", { className: "board__progress-fill", style: { width: `${(totalTaken / totalCards) * 100}%` } }) })] }), isFouled && (_jsx("div", { className: "board__foul-banner", children: "\u304A\u624B\u4ED8\u304D\uFF01\u6B21\u306E\u672D\u307E\u3067\u53C2\u52A0\u3067\u304D\u307E\u305B\u3093" })), _jsxs("div", { className: `board__grid${isFouled || cardResolved ? " board__grid--locked" : ""}`, children: [remainingCards.map((card) => (_jsx(EfudaCard, { card: card, taken: false, takenBy: null, isMe: false, onClick: () => { if (!cardResolved)
                            onTakeCard(card.id); } }, card.id))), takenCards.map((card) => (_jsx(EfudaCard, { card: card, taken: true, takenBy: null, isMe: false, onClick: () => { } }, card.id)))] }), _jsxs("div", { className: "board__scores", children: [_jsx("p", { className: "board__scores-title", children: "\u30B9\u30B3\u30A2" }), Object.entries(scores).sort(([, a], [, b]) => b - a).map(([name, score]) => (_jsxs("div", { className: "board__score-row", children: [_jsx("span", { className: `board__score-name ${name === playerName ? "board__score-name--me" : ""}`, children: name }), _jsx("span", { className: "board__score-val", children: score })] }, name)))] })] }));
}
