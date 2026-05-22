import { useState } from "react";
import type { GameSettings } from "../hooks/useGame";

type Props = {
  roomId: string;
  players: string[];
  isHost: boolean;
  playerName: string;
  onLeave: () => void;
  onStartGame: (settings: GameSettings) => void;
};

export function WaitingRoom({ roomId, players, isHost, playerName, onLeave, onStartGame }: Props) {
  const [copied, setCopied] = useState(false);
  const [yomiteMode, setYomiteMode] = useState<"ai" | "player">("ai");
  const [yomiteName, setYomiteName] = useState(playerName);
  const [endMode, setEndMode] = useState<"count" | "time">("count");
  const [endValue, setEndValue] = useState(5);

  const copyRoomId = () => {
    navigator.clipboard.writeText(roomId).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  };

  const handleStart = () => {
    onStartGame({
      yomite_mode: yomiteMode,
      yomite_name: yomiteMode === "player" ? yomiteName : playerName,
      end_mode: endMode,
      end_value: endValue,
    });
  };

  return (
    <div className="waiting">
      <div className="waiting__card">
        <p className="waiting__label">ルームID</p>
        <div className="waiting__room-id-row">
          <span className="waiting__room-id">{roomId}</span>
          <button type="button" className="waiting__copy-btn" onClick={copyRoomId}>
            {copied ? "コピーしました" : "コピー"}
          </button>
        </div>
        {isHost && <p className="waiting__hint">このIDを参加者に共有してください</p>}
        <div className="waiting__section">
          <p className="waiting__section-title">参加者 <span className="waiting__count">{players.length}/8</span></p>
          <ul className="waiting__players">
            {players.map((name) => (
              <li key={name}>
                <div className="waiting__player">
                  <span className="waiting__player-name">{name}</span>
                  {name === playerName && <span className="waiting__badge waiting__badge--you">あなた</span>}
                  {isHost && name === playerName && <span className="waiting__badge waiting__badge--host">ホスト</span>}
                </div>
              </li>
            ))}
          </ul>
        </div>
        {isHost ? (
          <div className="waiting__settings">
            <p className="waiting__section-title">ゲーム設定</p>
            <label className="waiting__settings-field">
              <span>よみてモード</span>
              <div className="waiting__radio-group">
                <label className="waiting__radio"><input type="radio" checked={yomiteMode === "ai"} onChange={() => setYomiteMode("ai")} />AIモード（自動読み上げ）</label>
                <label className="waiting__radio"><input type="radio" checked={yomiteMode === "player"} onChange={() => setYomiteMode("player")} />プレイヤー指名</label>
              </div>
            </label>
            {yomiteMode === "player" && (
              <label className="waiting__settings-field">
                <span>よみてを選ぶ</span>
                <select className="waiting__select" value={yomiteName} onChange={(e) => setYomiteName(e.target.value)}>
                  {players.map((p) => (<option key={p} value={p}>{p}</option>))}
                </select>
              </label>
            )}
            <label className="waiting__settings-field">
              <span>終了条件</span>
              <div className="waiting__radio-group">
                <label className="waiting__radio"><input type="radio" checked={endMode === "count"} onChange={() => { setEndMode("count"); setEndValue(5); }} />枚数</label>
                <label className="waiting__radio"><input type="radio" checked={endMode === "time"} onChange={() => { setEndMode("time"); setEndValue(60); }} />時間</label>
              </div>
            </label>
            <label className="waiting__settings-field">
              <span>{endMode === "count" ? "取る枚数" : "制限時間（秒）"}</span>
              <input type="number" className="waiting__number-input" min={endMode === "count" ? 1 : 10} max={endMode === "count" ? 10 : 300} value={endValue} onChange={(e) => setEndValue(Number(e.target.value))} />
            </label>
            <button type="button" className="waiting__start-btn" onClick={handleStart} disabled={players.length < 1}>ゲームスタート</button>
          </div>
        ) : (
          <p className="waiting__status">ホストがゲームを開始するまでお待ちください</p>
        )}
        <button type="button" className="waiting__leave" onClick={onLeave}>退出する</button>
      </div>
    </div>
  );
}
