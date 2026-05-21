import { useGame } from "./hooks/useGame";
import { RoomLobby, type LobbyResult } from "./components/RoomLobby";
import { WaitingRoom } from "./components/WaitingRoom";

export default function App() {
  const { phase, room, errorMsg, createRoom, joinRoom, leaveRoom, resetError } = useGame();

  const handleEnter = (result: LobbyResult) => {
    if (result.mode === "create") {
      createRoom(result.playerName);
    } else {
      joinRoom(result.playerName, result.roomId);
    }
  };

  if (phase === "waiting" && room) {
    return (
      <WaitingRoom
        roomId={room.roomId}
        players={room.players}
        isHost={room.isHost}
        playerName={room.playerName}
        onLeave={leaveRoom}
      />
    );
  }

  return (
    <RoomLobby
      onEnter={handleEnter}
      loading={phase === "connecting"}
      serverError={phase === "error" ? (errorMsg ?? "エラーが発生しました") : null}
    />
  );
}
