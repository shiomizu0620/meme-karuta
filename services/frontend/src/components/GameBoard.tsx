import { useEffect, useRef } from "react";
import type { RoomState } from "../hooks/useGame";
import { EfudaCard } from "./EfudaCard";

type Props = {
  room: RoomState;
  onTakeCard: (cardId: number) => void;
  onNextCard: () => void;
  isFouled: boolean;
  cardResolved: boolean;
};

export function GameBoard({ room, onTakeCard, onNextCard, isFouled, cardResolved }: Props) {
  const { game, playerName } = room;
  const utteranceRef = useRef<SpeechSynthesisUtterance | null>(null);

  const isAiMode = game?.settings.yomite_mode === "ai";
  const currentCard = game?.currentCard ?? null;

  useEffect(() => {
    if (!isAiMode || !currentCard) return;
    window.speechSynthesis.cancel();
    const utter = new SpeechSynthesisUtterance(currentCard.yomi);
    utter.lang = "ja-JP";
    utteranceRef.current = utter;
    window.speechSynthesis.speak(utter);
    return () => { window.speechSynthesis.cancel(); };
  }, [isAiMode, currentCard]);

  if (!game) return null;

  const { cards, settings, takenCardIds, scores } = game;
  const isYomite = isAiMode || settings.yomite_name === playerName;
  const remainingCards = cards.filter((c) => !takenCardIds.has(c.id));
  const takenCards = cards.filter((c) => takenCardIds.has(c.id));
  const totalTaken = takenCardIds.size;
  const totalCards = cards.length;

  return (
    <div className="board">
      <div className="board__reading">
        <div className="board__reading-inner">
          {currentCard ? (
            <>
              {isYomite && !isAiMode ? (
                <p className="board__yomi">{currentCard.yomi}</p>
              ) : isAiMode ? (
                <p className="board__yomi board__yomi--ai">🔊 {currentCard.yomi}</p>
              ) : (
                <p className="board__yomi board__yomi--hidden">よみてが読み上げ中…</p>
              )}
              <p className="board__fuda-hint">{currentCard.fuda}</p>
            </>
          ) : (
            <p className="board__yomi board__yomi--hidden">準備中…</p>
          )}
        </div>
        {isYomite && (
          <button type="button" className="board__next-btn" onClick={onNextCard} disabled={!cardResolved}>次の札へ →</button>
        )}
      </div>
      <div className="board__progress-row">
        <span className="board__progress-text">残り {remainingCards.length} / {totalCards} 枚</span>
        <div className="board__progress-bar">
          <div className="board__progress-fill" style={{ width: `${(totalTaken / totalCards) * 100}%` }} />
        </div>
      </div>
      {isFouled && (
        <div className="board__foul-banner">お手付き！次の札まで参加できません</div>
      )}
      <div className={`board__grid${isFouled ? " board__grid--locked" : ""}`}>
        {remainingCards.map((card) => (
          <EfudaCard key={card.id} card={card} taken={false} takenBy={null} isMe={false} onClick={() => onTakeCard(card.id)} />
        ))}
        {takenCards.map((card) => (
          <EfudaCard key={card.id} card={card} taken takenBy={null} isMe={false} onClick={() => {}} />
        ))}
      </div>
      <div className="board__scores">
        <p className="board__scores-title">スコア</p>
        {Object.entries(scores).sort(([, a], [, b]) => b - a).map(([name, score]) => (
          <div key={name} className="board__score-row">
            <span className={`board__score-name ${name === playerName ? "board__score-name--me" : ""}`}>{name}</span>
            <span className="board__score-val">{score}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
