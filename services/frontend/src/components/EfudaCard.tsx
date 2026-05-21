import { useEffect, useState } from "react";
import { motion } from "framer-motion";
import type { Card } from "../hooks/useGame";

const BURST_COUNT = 22;
const BURST_LINES = Array.from({ length: BURST_COUNT }, (_, i) => {
  const angle = (i / BURST_COUNT) * 2 * Math.PI;
  return {
    x1: 50 + 7 * Math.cos(angle),
    y1: 75 + 7 * Math.sin(angle),
    x2: 50 + 105 * Math.cos(angle),
    y2: 75 + 105 * Math.sin(angle),
    w: i % 5 === 0 ? 3.5 : i % 3 === 0 ? 2 : 0.9,
  };
});

function BurstEffect({ onDone }: { onDone: () => void }) {
  return (
    <motion.div
      className="efuda__burst"
      initial={{ opacity: 1 }}
      animate={{ opacity: 0 }}
      transition={{ duration: 0.55, ease: "easeOut" }}
      onAnimationComplete={onDone}
    >
      <motion.div
        className="efuda__burst-flash"
        initial={{ opacity: 1 }}
        animate={{ opacity: 0 }}
        transition={{ duration: 0.15, ease: "easeOut" }}
      />
      <svg className="efuda__burst-svg" viewBox="0 0 100 150">
        {BURST_LINES.map((l, i) => (
          <line
            key={i}
            x1={l.x1} y1={l.y1}
            x2={l.x2} y2={l.y2}
            stroke="#1a1a1a"
            strokeWidth={l.w}
          />
        ))}
      </svg>
    </motion.div>
  );
}

type Props = {
  card: Card;
  taken: boolean;
  takenBy: string | null;
  isMe: boolean;
  onClick: () => void;
  /** コレクション画面では true: 表面（画像）から始めてタップで切り替え */
  collectionMode?: boolean;
};

export function EfudaCard({ card, taken, takenBy, isMe, onClick, collectionMode = false }: Props) {
  const [flipped, setFlipped] = useState(false);
  const [showBurst, setShowBurst] = useState(() => taken && !collectionMode);

  // 取った瞬間（taken=true でマウント、ゲーム盤面）に自動フリップ
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (taken && !collectionMode) {
      setFlipped(true);
    }
  }, []);

  const handleClick = () => {
    if (taken) {
      setFlipped((f) => !f);
      return;
    }
    onClick();
  };

  return (
    <div
      className={`efuda ${taken ? "efuda--taken" : ""} ${isMe && taken ? "efuda--mine" : ""}`}
      onClick={handleClick}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => e.key === "Enter" && handleClick()}
      aria-label={card.fuda}
    >
      <motion.div
        className="efuda__inner"
        animate={{ rotateY: flipped ? 180 : 0 }}
        transition={{ duration: 0.4, ease: "easeInOut" }}
        style={{ transformStyle: "preserve-3d", position: "relative" }}
      >
        {/* 表面: ミーム画像 */}
        <div className="efuda__face efuda__face--front">
          <img
            src={card.image}
            alt={card.fuda}
            className="efuda__img"
            onError={(e) => {
              (e.currentTarget as HTMLImageElement).style.display = "none";
            }}
          />
          <p className="efuda__fuda">{card.fuda}</p>
          {taken && takenBy && (
            <div className="efuda__taken-overlay">
              <span>{takenBy}</span>
            </div>
          )}
        </div>

        {/* 裏面: セリフ + ミーム名 */}
        <div className="efuda__face efuda__face--back">
          <p className="efuda__yomi">{card.yomi}</p>
          <p className="efuda__fuda-back">{card.fuda}</p>
        </div>
      </motion.div>

      {/* 集中線エフェクト: 取った瞬間のみ表示 */}
      {showBurst && <BurstEffect onDone={() => setShowBurst(false)} />}
    </div>
  );
}
