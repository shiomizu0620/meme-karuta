import { useCallback, useEffect, useRef, useState } from "react";
import { useSocket } from "./useSocket";

export type Phase = "idle" | "connecting" | "waiting" | "playing" | "finished" | "error";

export interface Card { id: number; fuda: string; yomi: string; image: string; }

export interface GameSettings {
  yomite_mode: "ai" | "player";
  yomite_name: string;
  end_mode: "count" | "time";
  end_value: number;
  selected_sets: string[];
}

export interface GameState {
  cards: Card[];
  settings: GameSettings;
  currentCard: Card | null;
  currentCardIndex: number;
  takenCardIds: Set<number>;
  scores: Record<string, number>;
}

export interface RoomState {
  roomId: string;
  players: string[];
  isHost: boolean;
  playerName: string;
  game: GameState | null;
}

const GATEWAY_URL =
  (import.meta as unknown as { env: Record<string, string> }).env
    .VITE_GATEWAY_URL ?? "http://localhost:8080";

function recordCollected(playerName: string, cardId: number): void {
  fetch(`${GATEWAY_URL}/api/pokedex/collect`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ player_name: playerName, card_id: cardId }),
  }).catch(() => {});
}

export function useGame() {
  const [phase, setPhase] = useState<Phase>("idle");
  const [room, setRoom] = useState<RoomState | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [isFouled, setIsFouled] = useState(false);
  const [cardResolved, setCardResolved] = useState(false);
  const pendingRef = useRef<Record<string, unknown> | null>(null);
  const playerNameRef = useRef("");

  const handleMessage = useCallback((msg: Record<string, unknown>) => {
    const t = msg.type;
    if (t === "room_created") {
      setRoom({ roomId: String(msg.room_id), players: [String(msg.player_name)], isHost: true, playerName: String(msg.player_name), game: null });
      setPhase("waiting");
    } else if (t === "room_joined") {
      setRoom({ roomId: String(msg.room_id), players: (msg.players as string[]) ?? [], isHost: false, playerName: playerNameRef.current, game: null });
      setPhase("waiting");
    } else if (t === "player_joined") {
      setRoom((p) => p ? { ...p, players: [...p.players, String(msg.player_name)] } : p);
    } else if (t === "player_left") {
      setRoom((p) => p ? { ...p, players: p.players.filter((x) => x !== String(msg.player_name)) } : p);
    } else if (t === "game_started") {
      setCardResolved(false);
      setRoom((p) => p ? { ...p, game: { cards: (msg.cards as Card[]) ?? [], settings: msg.settings as GameSettings, currentCard: null, currentCardIndex: -1, takenCardIds: new Set(), scores: {} } } : p);
      setPhase("playing");
    } else if (t === "foul") {
      setRoom((p) => p?.game ? { ...p, game: { ...p.game, scores: msg.scores as Record<string, number> } } : p);
      if (String(msg.player) === playerNameRef.current) setIsFouled(true);
      if (msg.all_fouled) setCardResolved(true);
    } else if (t === "card_reading") {
      setIsFouled(false);
      setCardResolved(false);
      setRoom((p) => p?.game ? { ...p, game: { ...p.game, currentCard: msg.card as Card, currentCardIndex: msg.index as number } } : p);
    } else if (t === "card_taken") {
      const cardId = msg.card_id as number;
      const winner = String(msg.winner ?? "");
      setCardResolved(true);
      setRoom((p) => p?.game ? { ...p, game: { ...p.game, takenCardIds: new Set([...p.game.takenCardIds, cardId]), scores: msg.scores as Record<string, number> } } : p);
      if (winner && winner === playerNameRef.current) {
        recordCollected(winner, cardId);
      }
    } else if (t === "game_over") {
      setRoom((p) => p?.game ? { ...p, game: { ...p.game, scores: msg.scores as Record<string, number> } } : p);
      setPhase("finished");
    } else if (t === "error") {
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

  const createRoom = useCallback((playerName: string) => {
    playerNameRef.current = playerName;
    pendingRef.current = { type: "create_room", player_name: playerName, max_players: 8 };
    setPhase("connecting");
    setErrorMsg(null);
    connect();
  }, [connect]);

  const joinRoom = useCallback((playerName: string, roomId: string) => {
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

  const startGame = useCallback((settings: GameSettings) => send({ type: "start_game", ...settings }), [send]);
  const nextCard = useCallback(() => send({ type: "next_card" }), [send]);
  const takeCard = useCallback((cardId: number) => send({ type: "take_card", card_id: cardId }), [send]);
  const resetError = useCallback(() => { setPhase("idle"); setErrorMsg(null); }, []);

  return { phase, room, errorMsg, isFouled, cardResolved, createRoom, joinRoom, leaveRoom, startGame, nextCard, takeCard, resetError };
}
