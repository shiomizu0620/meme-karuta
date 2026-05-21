import { useCallback, useEffect, useRef, useState } from "react";
import { useSocket } from "./useSocket";

export type Phase = "idle" | "connecting" | "waiting" | "playing" | "finished" | "error";

export interface Card {
  id: number;
  fuda: string;
  yomi: string;
  image: string;
}

export interface GameSettings {
  yomite_mode: "ai" | "player";
  yomite_name: string;
  end_mode: "count" | "time";
  end_value: number;
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

export function useGame() {
  const [phase, setPhase] = useState<Phase>("idle");
  const [room, setRoom] = useState<RoomState | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const pendingRef = useRef<Record<string, unknown> | null>(null);
  const playerNameRef = useRef("");

  const handleMessage = useCallback((msg: Record<string, unknown>) => {
    switch (msg.type) {
      case "room_created":
        setRoom({
          roomId: String(msg.room_id),
          players: [String(msg.player_name)],
          isHost: true,
          playerName: String(msg.player_name),
          game: null,
        });
        setPhase("waiting");
        break;

      case "room_joined":
        setRoom({
          roomId: String(msg.room_id),
          players: (msg.players as string[]) ?? [],
          isHost: false,
          playerName: playerNameRef.current,
          game: null,
        });
        setPhase("waiting");
        break;

      case "player_joined":
        setRoom((prev) =>
          prev
            ? { ...prev, players: [...prev.players, String(msg.player_name)] }
            : prev
        );
        break;

      case "player_left":
        setRoom((prev) =>
          prev
            ? {
                ...prev,
                players: prev.players.filter(
                  (p) => p !== String(msg.player_name)
                ),
              }
            : prev
        );
        break;

      case "game_started":
        setRoom((prev) =>
          prev
            ? {
                ...prev,
                game: {
                  cards: (msg.cards as Card[]) ?? [],
                  settings: msg.settings as GameSettings,
                  currentCard: null,
                  currentCardIndex: -1,
                  takenCardIds: new Set(),
                  scores: {},
                },
              }
            : prev
        );
        setPhase("playing");
        break;

      case "card_reading":
        setRoom((prev) =>
          prev?.game
            ? {
                ...prev,
                game: {
                  ...prev.game,
                  currentCard: msg.card as Card,
                  currentCardIndex: msg.index as number,
                },
              }
            : prev
        );
        break;

      case "card_taken":
        setRoom((prev) =>
          prev?.game
            ? {
                ...prev,
                game: {
                  ...prev.game,
                  takenCardIds: new Set([
                    ...prev.game.takenCardIds,
                    msg.card_id as number,
                  ]),
                  scores: msg.scores as Record<string, number>,
                },
              }
            : prev
        );
        break;

      case "game_over":
        setRoom((prev) =>
          prev?.game
            ? {
                ...prev,
                game: {
                  ...prev.game,
                  scores: msg.scores as Record<string, number>,
                },
              }
            : prev
        );
        setPhase("finished");
        break;

      case "error":
        setErrorMsg(String(msg.message));
        if (phase === "connecting") setPhase("error");
        break;
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const { status, connect, send, disconnect } = useSocket(handleMessage);

  useEffect(() => {
    if (status === "open" && pendingRef.current) {
      send(pendingRef.current);
      pendingRef.current = null;
    }
    if (status === "error" && phase === "connecting") {
      setPhase("error");
      setErrorMsg("サーバーに接続できませんでした");
    }
  }, [status, send, phase]);

  const createRoom = useCallback(
    (playerName: string) => {
      playerNameRef.current = playerName;
      pendingRef.current = {
        type: "create_room",
        player_name: playerName,
        max_players: 8,
      };
      setPhase("connecting");
      setErrorMsg(null);
      connect();
    },
    [connect]
  );

  const joinRoom = useCallback(
    (playerName: string, roomId: string) => {
      playerNameRef.current = playerName;
      pendingRef.current = {
        type: "join_room",
        player_name: playerName,
        room_id: roomId,
      };
      setPhase("connecting");
      setErrorMsg(null);
      connect();
    },
    [connect]
  );

  const leaveRoom = useCallback(() => {
    send({ type: "leave_room" });
    disconnect();
    setRoom(null);
    setPhase("idle");
    setErrorMsg(null);
  }, [send, disconnect]);

  const startGame = useCallback(
    (settings: GameSettings) => {
      send({ type: "start_game", ...settings });
    },
    [send]
  );

  const nextCard = useCallback(() => {
    send({ type: "next_card" });
  }, [send]);

  const takeCard = useCallback(
    (cardId: number) => {
      send({ type: "take_card", card_id: cardId });
    },
    [send]
  );

  const resetError = useCallback(() => {
    setPhase("idle");
    setErrorMsg(null);
  }, []);

  return {
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
  };
}
