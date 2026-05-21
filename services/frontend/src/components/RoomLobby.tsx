import { useState } from "react";
import { motion } from "framer-motion";

export type LobbyResult =
  | { mode: "create"; playerName: string }
  | { mode: "join"; playerName: string; roomId: string };

type Props = {
  onEnter: (result: LobbyResult) => void;
  loading?: boolean;
  serverError?: string | null;
};

type Tab = "create" | "join";

const ROOM_ID_PATTERN = /^[A-Z0-9]{4,8}$/;

export function RoomLobby({ onEnter, loading = false, serverError = null }: Props) {
  const [tab, setTab] = useState<Tab>("create");
  const [playerName, setPlayerName] = useState("");
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
      <motion.div
        className="lobby__card"
        initial={{ opacity: 0, y: 12 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.25 }}
      >
        <h1 className="lobby__title">ネットミームカルタ</h1>
        <p className="lobby__subtitle">最大8人で遊べるリアルタイムカルタ</p>

        <div className="lobby__tabs" role="tablist">
          <TabButton active={tab === "create"} onClick={() => setTab("create")} disabled={loading}>
            ルームを作る
          </TabButton>
          <TabButton active={tab === "join"} onClick={() => setTab("join")} disabled={loading}>
            ルームに参加
          </TabButton>
        </div>

        <form className="lobby__form" onSubmit={handleSubmit}>
          <label className="lobby__field">
            <span>プレイヤー名</span>
            <input
              type="text"
              value={playerName}
              onChange={(e) => setPlayerName(e.target.value)}
              placeholder="例: そうはならんやろ太郎"
              maxLength={12}
              autoFocus
              disabled={loading}
            />
          </label>

          {tab === "join" && (
            <label className="lobby__field">
              <span>ルームID</span>
              <input
                type="text"
                value={roomId}
                onChange={(e) => setRoomId(e.target.value.toUpperCase())}
                placeholder="例: ABCD12"
                maxLength={8}
                disabled={loading}
              />
            </label>
          )}

          {error && <p className="lobby__error">{error}</p>}

          <button type="submit" className="lobby__submit" disabled={loading}>
            {loading
              ? "接続中…"
              : tab === "create"
              ? "ルームを作成する"
              : "ルームに入る"}
          </button>
        </form>

        <p className="lobby__hint">
          {tab === "create"
            ? "あなたがホストになり、ゲーム設定を決められます。"
            : "ホストから共有されたルームIDを入力してください。"}
        </p>
      </motion.div>
    </div>
  );
}

function TabButton({
  active,
  disabled,
  onClick,
  children,
}: {
  active: boolean;
  disabled: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      role="tab"
      aria-selected={active}
      className={`lobby__tab ${active ? "lobby__tab--active" : ""}`}
      onClick={onClick}
      disabled={disabled}
    >
      {children}
    </button>
  );
}
