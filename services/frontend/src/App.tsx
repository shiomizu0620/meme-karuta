import { useGame } from "./hooks/useGame";
import { RoomLobby, type LobbyResult } from "./components/RoomLobby";
import { WaitingRoom } from "./components/WaitingRoom";
import { GameBoard } from "./components/GameBoard";
import { ScoreBoard } from "./components/ScoreBoard";

export default function App() {
  const g = useGame();
  const handleEnter = (r: LobbyResult) => r.mode === "create" ? g.createRoom(r.playerName) : g.joinRoom(r.playerName, r.roomId);

  if (g.phase === "waiting" && g.room) {
    return <WaitingRoom roomId={g.room.roomId} players={g.room.players} isHost={g.room.isHost} playerName={g.room.playerName} onLeave={g.leaveRoom} onStartGame={g.startGame} />;
  }
  if (g.phase === "playing" && g.room) {
    return <GameBoard room={g.room} onTakeCard={g.takeCard} onNextCard={g.nextCard} />;
  }
  if (g.phase === "finished" && g.room) {
    return <ScoreBoard room={g.room} onPlayAgain={g.leaveRoom} />;
  }
  return <RoomLobby onEnter={handleEnter} loading={g.phase === "connecting"} serverError={g.phase === "error" ? (g.errorMsg ?? "エラーが発生しました") : null} />;
}
