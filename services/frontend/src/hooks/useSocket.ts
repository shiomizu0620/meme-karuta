import { useCallback, useEffect, useRef, useState } from "react";

export type SocketStatus = "connecting" | "open" | "closed" | "error";

type IncomingMessage = Record<string, unknown>;
type MessageHandler = (msg: IncomingMessage) => void;

const REALTIME_URL =
  (import.meta as unknown as { env: Record<string, string> }).env
    .VITE_REALTIME_URL ?? "ws://localhost:4000/ws";

export function useSocket(onMessage: MessageHandler) {
  const wsRef = useRef<WebSocket | null>(null);
  const [status, setStatus] = useState<SocketStatus>("closed");

  // always call the latest handler without recreating connect/send
  const handlerRef = useRef(onMessage);
  useEffect(() => { handlerRef.current = onMessage; }, [onMessage]);

  const connect = useCallback(() => {
    if (wsRef.current?.readyState === WebSocket.OPEN) return;

    setStatus("connecting");
    const ws = new WebSocket(REALTIME_URL);
    wsRef.current = ws;

    ws.onopen = () => setStatus("open");
    ws.onclose = () => setStatus("closed");
    ws.onerror = () => setStatus("error");
    ws.onmessage = (e) => {
      try {
        handlerRef.current(JSON.parse(e.data as string) as IncomingMessage);
      } catch {
        // ignore malformed frames
      }
    };
  }, []);

  const send = useCallback((payload: Record<string, unknown>) => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify(payload));
    }
  }, []);

  const disconnect = useCallback(() => {
    wsRef.current?.close();
    wsRef.current = null;
  }, []);

  useEffect(() => () => { wsRef.current?.close(); }, []);

  return { status, connect, send, disconnect };
}
