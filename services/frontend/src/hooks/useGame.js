import { useCallback, useEffect, useRef, useState } from "react";
import { useSocket } from "./useSocket";
export const CUSTOM_CARD_MAX = 10;
const GATEWAY_URL = import.meta.env
    .VITE_GATEWAY_URL ?? "http://localhost:8080";
function recordCollected(playerName, cardId) {
    fetch(`${GATEWAY_URL}/api/pokedex/collect`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ player_name: playerName, card_id: cardId }),
    }).catch(() => { });
}
export function useGame() {
    const [phase, setPhase] = useState("idle");
    const [room, setRoom] = useState(null);
    const [errorMsg, setErrorMsg] = useState(null);
    const [isFouled, setIsFouled] = useState(false);
    const [cardResolved, setCardResolved] = useState(false);
    const pendingRef = useRef(null);
    const playerNameRef = useRef("");
    const handleMessage = useCallback((msg) => {
        const t = msg.type;
        if (t === "room_created") {
            setRoom({ roomId: String(msg.room_id), players: [String(msg.player_name)], isHost: true, playerName: String(msg.player_name), game: null, customCards: [] });
            setPhase("waiting");
        }
        else if (t === "room_joined") {
            setRoom({ roomId: String(msg.room_id), players: msg.players ?? [], isHost: false, playerName: playerNameRef.current, game: null, customCards: msg.custom_cards ?? [] });
            setPhase("waiting");
        }
        else if (t === "custom_card_added") {
            setRoom((p) => p ? { ...p, customCards: [...p.customCards, msg.card] } : p);
        }
        else if (t === "custom_card_removed") {
            const removedId = msg.id;
            setRoom((p) => p ? { ...p, customCards: p.customCards.filter((c) => c.id !== removedId) } : p);
        }
        else if (t === "player_joined") {
            setRoom((p) => p ? { ...p, players: [...p.players, String(msg.player_name)] } : p);
        }
        else if (t === "player_left") {
            setRoom((p) => p ? { ...p, players: p.players.filter((x) => x !== String(msg.player_name)) } : p);
        }
        else if (t === "game_started") {
            setCardResolved(false);
            setRoom((p) => p ? { ...p, game: { cards: msg.cards ?? [], settings: msg.settings, currentCard: null, currentCardIndex: -1, takenCardIds: new Set(), scores: {} } } : p);
            setPhase("playing");
        }
        else if (t === "foul") {
            setRoom((p) => p?.game ? { ...p, game: { ...p.game, scores: msg.scores } } : p);
            if (String(msg.player) === playerNameRef.current)
                setIsFouled(true);
            if (msg.all_fouled)
                setCardResolved(true);
        }
        else if (t === "card_reading") {
            setIsFouled(false);
            setCardResolved(false);
            if (typeof window !== "undefined" && window.speechSynthesis)
                window.speechSynthesis.cancel();
            setRoom((p) => p?.game ? { ...p, game: { ...p.game, currentCard: msg.card, currentCardIndex: msg.index } } : p);
        }
        else if (t === "card_speak") {
            const yomi = String(msg.yomi ?? "");
            if (yomi && typeof window !== "undefined" && window.speechSynthesis) {
                window.speechSynthesis.cancel();
                const utter = new SpeechSynthesisUtterance(yomi);
                utter.lang = "ja-JP";
                window.speechSynthesis.speak(utter);
            }
        }
        else if (t === "card_taken") {
            const cardId = msg.card_id;
            const winner = String(msg.winner ?? "");
            setCardResolved(true);
            setRoom((p) => p?.game ? { ...p, game: { ...p.game, takenCardIds: new Set([...p.game.takenCardIds, cardId]), scores: msg.scores } } : p);
            if (winner && winner === playerNameRef.current && cardId > 0 && cardId < 1_000_000)
                recordCollected(winner, cardId);
        }
        else if (t === "game_over") {
            setRoom((p) => p?.game ? { ...p, game: { ...p.game, scores: msg.scores } } : p);
            setPhase("finished");
        }
        else if (t === "error") {
            setErrorMsg(String(msg.message));
            setPhase((cur) => cur === "connecting" ? "error" : cur);
        }
    }, []);
    const { status, connect, send, disconnect } = useSocket(handleMessage);
    useEffect(() => {
        if (status === "open" && pendingRef.current) {
            send(pendingRef.current);
            pendingRef.current = null;
        }
        if ((status === "error" || status === "closed") && phase === "connecting") {
            setPhase("error");
            setErrorMsg("サーバーに接続できませんでした");
        }
    }, [status, send, phase]);
    const createRoom = useCallback((playerName) => {
        playerNameRef.current = playerName;
        pendingRef.current = { type: "create_room", player_name: playerName, max_players: 8 };
        setPhase("connecting");
        setErrorMsg(null);
        connect();
    }, [connect]);
    const joinRoom = useCallback((playerName, roomId) => {
        playerNameRef.current = playerName;
        pendingRef.current = { type: "join_room", player_name: playerName, room_id: roomId };
        setPhase("connecting");
        setErrorMsg(null);
        connect();
    }, [connect]);
    const leaveRoom = useCallback(() => {
        send({ type: "leave_room" });
        disconnect();
        setRoom(null);
        setPhase("idle");
        setErrorMsg(null);
        setIsFouled(false);
        setCardResolved(false);
    }, [send, disconnect]);
    const startGame = useCallback((settings) => send({ type: "start_game", ...settings }), [send]);
    const nextCard = useCallback(() => send({ type: "next_card" }), [send]);
    const speakCard = useCallback(() => send({ type: "speak_card" }), [send]);
    const takeCard = useCallback((cardId) => send({ type: "take_card", card_id: cardId }), [send]);
    const addCustomCard = useCallback((input) => send({ type: "add_custom_card", fuda: input.fuda, yomi: input.yomi, image: input.image }), [send]);
    const removeCustomCard = useCallback((id) => send({ type: "remove_custom_card", id }), [send]);
    const resetError = useCallback(() => { setPhase("idle"); setErrorMsg(null); }, []);
    return { phase, room, errorMsg, isFouled, cardResolved, createRoom, joinRoom, leaveRoom, startGame, nextCard, speakCard, takeCard, addCustomCard, removeCustomCard, resetError };
}
