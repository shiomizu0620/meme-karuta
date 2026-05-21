import { useCallback, useEffect, useRef, useState } from "react";
import { useSocket } from "./useSocket";

export type Phase = "idle" | "connecting" | "waiting" | "error";

export type RoomState = {
  roomId: string;
  players: string[];
  isHost: boolean;
  playerName: string;
};

export function useGame() {
  const [phase, setPhase] = useState<Phase>("idle");
  const [room, setRoom] = useState<RoomState | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  // queued message sent as soon as the socket opens
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
        });
        setPhase("waiting");
        break;

      case "room_joined":
        setRoom({
          roomId: String(msg.room_id),
          players: (msg.players as string[]) ?? [],
          isHost: false,
          playerName: playerNameRef.current,
        });
        setPhase("waiting");
        break;

      case "player_joined":
        setRoom((prev) =>
          prev ? { ...prev, players: [...prev.players, String(msg.player_name)] } : prev
        );
        break;

      case "player_left":
        setRoom((prev) =>
          prev
            ? { ...prev, players: prev.players.filter((p) => p !== String(msg.player_name)) }
            : prev
        );
        break;

      case "error":
        setErrorMsg(String(msg.message));
        setPhase("error");
        break;
    }
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
      pendingRef.current = { type: "create_room", player_name: playerName, max_players: 8 };
      setPhase("connecting");
      setErrorMsg(null);
      connect();
    },
    [connect]
  );

  const joinRoom = useCallback(
    (playerName: string, roomId: string) => {
      playerNameRef.current = playerName;
      pendingRef.current = { type: "join_room", player_name: playerName, room_id: roomId };
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

  const resetError = useCallback(() => {
    setPhase("idle");
    setErrorMsg(null);
  }, []);

  return { phase, room, errorMsg, createRoom, joinRoom, leaveRoom, resetError };
}
