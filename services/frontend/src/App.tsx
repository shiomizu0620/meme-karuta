import { useGame } from "./hooks/useGame";
import { RoomLobby, type LobbyResult } from "./components/RoomLobby";
import { WaitingRoom } from "./components/WaitingRoom";
import { GameBoard } from "./components/GameBoard";
import { ScoreBoard } from "./components/ScoreBoard";

export default function App() {
  const {
    phase,
    room,
    errorMsg,
    createRoom,
    joinRoom,
    leaveRoom,
    startGame,
    nextCard,
    takeCard,
    resetError,
  } = useGame();

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
        onStartGame={startGame}
      />
    );
  }

  if (phase === "playing" && room) {
    return (
      <GameBoard
        room={room}
        onTakeCard={takeCard}
        onNextCard={nextCard}
      />
    );
  }

  if (phase === "finished" && room) {
    return <ScoreBoard room={room} onPlayAgain={leaveRoom} />;
  }

  return (
    <RoomLobby
      onEnter={handleEnter}
      loading={phase === "connecting"}
      serverError={phase === "error" ? (errorMsg ?? "エラーが発生しました") : null}
    />
  );
}
