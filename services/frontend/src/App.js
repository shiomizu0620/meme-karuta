import { jsx as _jsx } from "react/jsx-runtime";
import { useState } from "react";
import { useGame } from "./hooks/useGame";
import { RoomLobby } from "./components/RoomLobby";
import { WaitingRoom } from "./components/WaitingRoom";
import { GameBoard } from "./components/GameBoard";
import { ScoreBoard } from "./components/ScoreBoard";
import { Pokedex } from "./components/Pokedex";
export default function App() {
    const g = useGame();
    const [showPokedex, setShowPokedex] = useState(false);
    const [savedPlayerName, setSavedPlayerName] = useState(() => localStorage.getItem("karuta_player_name") ?? "");
    const handleEnter = (r) => {
        setSavedPlayerName(r.playerName);
        localStorage.setItem("karuta_player_name", r.playerName);
        r.mode === "create" ? g.createRoom(r.playerName) : g.joinRoom(r.playerName, r.roomId);
    };
    if (showPokedex) {
        return _jsx(Pokedex, { playerName: savedPlayerName, onClose: () => setShowPokedex(false) });
    }
    if (g.phase === "waiting" && g.room) {
        return _jsx(WaitingRoom, { roomId: g.room.roomId, players: g.room.players, isHost: g.room.isHost, playerName: g.room.playerName, customCards: g.room.customCards, onLeave: g.leaveRoom, onStartGame: g.startGame, onAddCustomCard: g.addCustomCard, onRemoveCustomCard: g.removeCustomCard, errorMsg: g.errorMsg });
    }
    if (g.phase === "playing" && g.room) {
        return _jsx(GameBoard, { room: g.room, onTakeCard: g.takeCard, onNextCard: g.nextCard, onSpeakCard: g.speakCard, isFouled: g.isFouled, cardResolved: g.cardResolved });
    }
    if (g.phase === "finished" && g.room) {
        return _jsx(ScoreBoard, { room: g.room, onPlayAgain: g.leaveRoom, onShowPokedex: () => setShowPokedex(true) });
    }
    return (_jsx(RoomLobby, { onEnter: handleEnter, onShowPokedex: () => setShowPokedex(true), savedPlayerName: savedPlayerName, loading: g.phase === "connecting", serverError: g.phase === "error" ? (g.errorMsg ?? "エラーが発生しました") : null }));
}
