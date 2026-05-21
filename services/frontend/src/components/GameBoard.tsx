import { useEffect, useRef } from "react";
import { motion, AnimatePresence } from "framer-motion";
import type { RoomState } from "../hooks/useGame";
import { EfudaCard } from "./EfudaCard";

type Props = {
  room: RoomState;
  onTakeCard: (cardId: number) => void;
  onNextCard: () => void;
};

export function GameBoard({ room, onTakeCard, onNextCard }: Props) {
  const { game, playerName } = room;
  const utteranceRef = useRef<SpeechSynthesisUtterance | null>(null);

  if (!game) return null;

  const { cards, settings, currentCard, takenCardIds, scores } = game;
  const isAiMode = settings.yomite_mode === "ai";
  const isYomite =
    isAiMode || settings.yomite_name === playerName;

  // AI モード: card_reading を受け取ったら自動で読み上げ
  // eslint-disable-next-line react-hooks/rules-of-hooks
  useEffect(() => {
    if (!isAiMode || !currentCard) return;
    window.speechSynthesis.cancel();
    const utter = new SpeechSynthesisUtterance(currentCard.yomi);
    utter.lang = "ja-JP";
    utteranceRef.current = utter;
    window.speechSynthesis.speak(utter);
    return () => { window.speechSynthesis.cancel(); };
  }, [isAiMode, currentCard]);

  const remainingCards = cards.filter((c) => !takenCardIds.has(c.id));
  const takenCards = cards.filter((c) => takenCardIds.has(c.id));

  // 誰がそのカードを取ったかを逆引き（スコアからは分からないのでcard_takenイベント側で管理するか
  // 簡易実装として取り主は非表示にせずスコア表示で代替）
  const takenByMap: Record<number, string> = {};

  const totalTaken = takenCardIds.size;
  const totalCards = cards.length;

  return (
    <div className="board">
      {/* ヘッダー: 読み上げエリア */}
      <div className="board__reading">
        <div className="board__reading-inner">
          {currentCard ? (
            <>
              {isYomite && !isAiMode ? (
                <p className="board__yomi">{currentCard.yomi}</p>
              ) : isAiMode ? (
                <p className="board__yomi board__yomi--ai">
                  🔊 {currentCard.yomi}
                </p>
              ) : (
                <p className="board__yomi board__yomi--hidden">
                  よみてが読み上げ中…
                </p>
              )}
              <p className="board__fuda-hint">{currentCard.fuda}</p>
            </>
          ) : (
            <p className="board__yomi board__yomi--hidden">準備中…</p>
          )}
        </div>

        {isYomite && (
          <button
            type="button"
            className="board__next-btn"
            onClick={onNextCard}
          >
            次の札へ →
          </button>
        )}
      </div>

      {/* 進捗バー */}
      <div className="board__progress-row">
        <span className="board__progress-text">
          残り {remainingCards.length} / {totalCards} 枚
        </span>
        <div className="board__progress-bar">
          <motion.div
            className="board__progress-fill"
            animate={{ width: `${(totalTaken / totalCards) * 100}%` }}
            transition={{ duration: 0.3 }}
          />
        </div>
      </div>

      {/* 絵札グリッド */}
      <div className="board__grid">
        <AnimatePresence>
          {remainingCards.map((card) => (
            <motion.div
              key={card.id}
              layout
              exit={{ scale: 0, opacity: 0 }}
              transition={{ duration: 0.25 }}
            >
              <EfudaCard
                card={card}
                taken={false}
                takenBy={null}
                isMe={false}
                onClick={() => onTakeCard(card.id)}
              />
            </motion.div>
          ))}
        </AnimatePresence>

        {takenCards.map((card) => (
          <EfudaCard
            key={card.id}
            card={card}
            taken
            takenBy={takenByMap[card.id] ?? null}
            isMe={false}
            onClick={() => {}}
          />
        ))}
      </div>

      {/* スコアサイドバー */}
      <div className="board__scores">
        <p className="board__scores-title">スコア</p>
        {Object.entries(scores)
          .sort(([, a], [, b]) => b - a)
          .map(([name, score]) => (
            <div key={name} className="board__score-row">
              <span
                className={`board__score-name ${name === playerName ? "board__score-name--me" : ""}`}
              >
                {name}
              </span>
              <span className="board__score-val">{score}</span>
            </div>
          ))}
      </div>
    </div>
  );
}
