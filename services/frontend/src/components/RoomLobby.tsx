import { useState } from "react";

export type LobbyResult =
  | { mode: "create"; playerName: string }
  | { mode: "join"; playerName: string; roomId: string };

type Props = {
  onEnter: (result: LobbyResult) => void;
  onShowPokedex: () => void;
  savedPlayerName?: string;
  loading?: boolean;
  serverError?: string | null;
};

const ROOM_ID_PATTERN = /^[A-Z0-9]{4,8}$/;

export function RoomLobby({ onEnter, onShowPokedex, savedPlayerName = "", loading = false, serverError = null }: Props) {
  const [tab, setTab] = useState<"create" | "join">("create");
  const [playerName, setPlayerName] = useState(savedPlayerName);
  const [roomId, setRoomId] = useState("");
  const [validationError, setValidationError] = useState<string | null>(null);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const name = playerName.trim();
    if (name.length < 1 || name.length > 12) {
      setValidationError("プレイヤー名は1〜12文字で入力してください");
      return;
    }
    if (tab === "join") {
      const id = roomId.trim().toUpperCase();
      if (!ROOM_ID_PATTERN.test(id)) {
        setValidationError("ルームIDは英数字4〜8文字で入力してください");
        return;
      }
      setValidationError(null);
      onEnter({ mode: "join", playerName: name, roomId: id });
      return;
    }
    setValidationError(null);
    onEnter({ mode: "create", playerName: name });
  };

  const error = validationError ?? serverError;

  return (
    <div className="lobby">
      <div className="lobby__card">
        <div className="lobby__title-row">
          <h1 className="lobby__title">ネットミームカルタ</h1>
          <button type="button" className="lobby__pokedex-btn" onClick={onShowPokedex} title="図鑑を見る">
            図鑑
          </button>
        </div>
        <p className="lobby__subtitle">最大8人で遊べるリアルタイムカルタ</p>
        <div className="lobby__tabs" role="tablist">
          <button type="button" role="tab" aria-selected={tab === "create"} className={`lobby__tab ${tab === "create" ? "lobby__tab--active" : ""}`} onClick={() => setTab("create")} disabled={loading}>ルームを作る</button>
          <button type="button" role="tab" aria-selected={tab === "join"} className={`lobby__tab ${tab === "join" ? "lobby__tab--active" : ""}`} onClick={() => setTab("join")} disabled={loading}>ルームに参加</button>
        </div>
        <form className="lobby__form" onSubmit={handleSubmit}>
          <label className="lobby__field">
            <span>プレイヤー名</span>
            <input type="text" value={playerName} onChange={(e) => setPlayerName(e.target.value)} placeholder="例: そうはならんやろ太郎" maxLength={12} autoFocus disabled={loading} />
          </label>
          {tab === "join" && (
            <label className="lobby__field">
              <span>ルームID</span>
              <input type="text" value={roomId} onChange={(e) => setRoomId(e.target.value.toUpperCase())} placeholder="例: ABCD12" maxLength={8} disabled={loading} />
            </label>
          )}
          {error && <p className="lobby__error">{error}</p>}
          <button type="submit" className="lobby__submit" disabled={loading}>
            {loading ? "接続中…" : tab === "create" ? "ルームを作成する" : "ルームに入る"}
          </button>
        </form>
        <p className="lobby__hint">
          {tab === "create" ? "あなたがホストになり、ゲーム設定を決められます。" : "ホストから共有されたルームIDを入力してください。"}
        </p>
      </div>
    </div>
  );
}
