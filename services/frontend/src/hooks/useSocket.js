import { useCallback, useEffect, useRef, useState } from "react";
const REALTIME_URL = import.meta.env
    .VITE_REALTIME_URL ?? "ws://localhost:4000/ws";
export function useSocket(onMessage) {
    const wsRef = useRef(null);
    const [status, setStatus] = useState("closed");
    // always call the latest handler without recreating connect/send
    const handlerRef = useRef(onMessage);
    useEffect(() => { handlerRef.current = onMessage; }, [onMessage]);
    const connect = useCallback(() => {
        if (wsRef.current?.readyState === WebSocket.OPEN)
            return;
        setStatus("connecting");
        const ws = new WebSocket(REALTIME_URL);
        wsRef.current = ws;
        ws.onopen = () => setStatus("open");
        ws.onclose = () => setStatus("closed");
        ws.onerror = () => setStatus("error");
        ws.onmessage = (e) => {
            try {
                handlerRef.current(JSON.parse(e.data));
            }
            catch {
                // ignore malformed frames
            }
        };
    }, []);
    const send = useCallback((payload) => {
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
