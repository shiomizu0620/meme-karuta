import { useEffect, useState } from "react";
import { motion } from "framer-motion";
import type { Card } from "../hooks/useGame";

type Props = {
  card: Card;
  taken: boolean;
  takenBy: string | null;
  isMe: boolean;
  onClick: () => void;
  collectionMode?: boolean;
};

export function EfudaCard({ card, taken, takenBy, isMe, onClick, collectionMode = false }: Props) {
  const [flipped, setFlipped] = useState(false);

  useEffect(() => {
    if (taken && !collectionMode) setFlipped(true);
  }, [taken, collectionMode]);

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
        <div className="efuda__face efuda__face--front">
          <img
            src={card.image}
            alt={card.fuda}
            className="efuda__img"
            onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = "none"; }}
          />
          <p className="efuda__fuda">{card.fuda}</p>
          {taken && takenBy && (<div className="efuda__taken-overlay"><span>{takenBy}</span></div>)}
        </div>
        <div className="efuda__face efuda__face--back">
          <p className="efuda__yomi">{card.yomi}</p>
          <p className="efuda__fuda-back">{card.fuda}</p>
        </div>
      </motion.div>
    </div>
  );
}
