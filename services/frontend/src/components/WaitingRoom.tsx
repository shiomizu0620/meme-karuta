import { useState } from "react";
import { motion, AnimatePresence } from "framer-motion";

type Props = {
  roomId: string;
  players: string[];
  isHost: boolean;
  playerName: string;
  onLeave: () => void;
};

export function WaitingRoom({ roomId, players, isHost, playerName, onLeave }: Props) {
  const [copied, setCopied] = useState(false);

  const copyRoomId = () => {
    navigator.clipboard.writeText(roomId).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  };

  return (
    <div className="waiting">
      <motion.div
        className="waiting__card"
        initial={{ opacity: 0, y: 12 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.25 }}
      >
        <p className="waiting__label">ルームID</p>
        <div className="waiting__room-id-row">
          <span className="waiting__room-id">{roomId}</span>
          {isHost && (
            <button className="waiting__copy-btn" onClick={copyRoomId}>
              {copied ? "コピーしました" : "コピー"}
            </button>
          )}
        </div>

        {isHost && (
          <p className="waiting__hint">
            このIDを参加者に共有してください
          </p>
        )}

        <div className="waiting__section">
          <p className="waiting__section-title">
            参加者 <span className="waiting__count">{players.length}/8</span>
          </p>
          <ul className="waiting__players">
            <AnimatePresence>
              {players.map((name) => (
                <motion.li
                  key={name}
                  className="waiting__player"
                  initial={{ opacity: 0, x: -8 }}
                  animate={{ opacity: 1, x: 0 }}
                  exit={{ opacity: 0, x: 8 }}
                  transition={{ duration: 0.15 }}
                >
                  <span className="waiting__player-name">{name}</span>
                  {name === playerName && (
                    <span className="waiting__badge waiting__badge--you">あなた</span>
                  )}
                  {isHost && name === playerName && (
                    <span className="waiting__badge waiting__badge--host">ホスト</span>
                  )}
                </motion.li>
              ))}
            </AnimatePresence>
          </ul>
        </div>

        <p className="waiting__status">
          {isHost
            ? "ゲーム設定はまもなく実装されます"
            : "ホストがゲームを開始するまでお待ちください"}
        </p>

        <button className="waiting__leave" onClick={onLeave}>
          退出する
        </button>
      </motion.div>
    </div>
  );
}
