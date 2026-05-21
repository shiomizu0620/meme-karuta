package com.example.memekaruta

import android.os.Handler
import android.os.Looper
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintWriter
import java.net.Socket
import java.net.URI
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.random.Random

/**
 * OkHttp を使わずに WebSocket ハンドシェイクを実装した軽量クライアント。
 * Meme Karuta の Elixir realtime サービスに接続する。
 */
class GameWebSocketClient(
    private val url: String,
    private val listener: Listener,
) {
    interface Listener {
        fun onOpen()
        fun onMessage(json: String)
        fun onClose(code: Int, reason: String)
        fun onError(message: String)
    }

    private val connected = AtomicBoolean(false)
    private val socketRef = AtomicReference<Socket?>(null)
    private val writerRef = AtomicReference<PrintWriter?>(null)
    private val mainHandler = Handler(Looper.getMainLooper())

    // ---- Public API ----

    fun connect() {
        if (connected.get()) return
        thread(name = "ws-connect") { runConnect() }
    }

    fun disconnect() {
        if (!connected.compareAndSet(true, false)) return
        safeClose()
        mainHandler.post { listener.onClose(1000, "Normal closure") }
    }

    fun send(json: String): Boolean {
        val writer = writerRef.get() ?: return false
        return runCatching {
            val frame = encodeTextFrame(json)
            synchronized(writer) {
                writer.print(frame)
                writer.flush()
            }
            true
        }.getOrElse {
            listener.onError("Send failed: ${it.message}")
            false
        }
    }

    fun isConnected(): Boolean = connected.get()

    // ---- Connection logic ----

    private fun runConnect() {
        val uri = URI.create(url)
        val host = uri.host
        val port = if (uri.port != -1) uri.port else 80
        val path = if (uri.path.isNullOrEmpty()) "/" else uri.path

        runCatching {
            val socket = Socket(host, port)
            socketRef.set(socket)

            val output = PrintWriter(socket.getOutputStream(), false)
            writerRef.set(output)
            val input = BufferedReader(InputStreamReader(socket.getInputStream()))

            performHandshake(output, input, host, port, path)
            connected.set(true)
            mainHandler.post { listener.onOpen() }
            readLoop(input)
        }.onFailure { e ->
            connected.set(false)
            safeClose()
            mainHandler.post { listener.onError(e.message ?: "Unknown connection error") }
        }
    }

    private fun performHandshake(
        out: PrintWriter,
        inp: BufferedReader,
        host: String,
        port: Int,
        path: String,
    ) {
        val key = generateWebSocketKey()
        val lines = buildString {
            append("GET $path HTTP/1.1\r\n")
            append("Host: $host:$port\r\n")
            append("Upgrade: websocket\r\n")
            append("Connection: Upgrade\r\n")
            append("Sec-WebSocket-Key: $key\r\n")
            append("Sec-WebSocket-Version: 13\r\n")
            append("\r\n")
        }
        out.print(lines)
        out.flush()

        val statusLine = inp.readLine() ?: throw IllegalStateException("No response from server")
        if (!statusLine.contains("101")) {
            throw IllegalStateException("WebSocket handshake failed: $statusLine")
        }

        val expectedAccept = computeAcceptKey(key)
        var wsAccept: String? = null

        while (true) {
            val line = inp.readLine() ?: break
            if (line.isEmpty()) break
            if (line.startsWith("Sec-WebSocket-Accept:", ignoreCase = true)) {
                wsAccept = line.substringAfter(":").trim()
            }
        }

        if (wsAccept != expectedAccept) {
            throw IllegalStateException("Invalid Sec-WebSocket-Accept: $wsAccept != $expectedAccept")
        }
    }

    private fun readLoop(inp: BufferedReader) {
        val rawStream = socketRef.get()?.getInputStream() ?: return
        val buffer = ByteArray(65536)

        while (connected.get()) {
            runCatching {
                val byte1 = rawStream.read()
                if (byte1 == -1) { disconnect(); return }
                val byte2 = rawStream.read()
                if (byte2 == -1) { disconnect(); return }

                val opcode = byte1 and 0x0F
                val payloadLen = (byte2 and 0x7F)

                val actualLen: Long = when {
                    payloadLen < 126  -> payloadLen.toLong()
                    payloadLen == 126 -> {
                        val b1 = rawStream.read(); val b2 = rawStream.read()
                        ((b1 shl 8) or b2).toLong()
                    }
                    else -> {
                        var len = 0L
                        repeat(8) { len = (len shl 8) or rawStream.read().toLong() }
                        len
                    }
                }

                when (opcode) {
                    0x1 -> {
                        val payload = readFully(rawStream, actualLen.toInt())
                        val text = String(payload, Charsets.UTF_8)
                        mainHandler.post { listener.onMessage(text) }
                    }
                    0x8 -> {
                        val code = if (actualLen >= 2) {
                            val p = readFully(rawStream, actualLen.toInt())
                            ((p[0].toInt() and 0xFF) shl 8) or (p[1].toInt() and 0xFF)
                        } else { 1000 }
                        connected.set(false)
                        mainHandler.post { listener.onClose(code, "Server closed") }
                        return
                    }
                    0x9 -> {
                        readFully(rawStream, actualLen.toInt())
                        val pong = encodePongFrame()
                        writerRef.get()?.let { synchronized(it) { it.print(pong); it.flush() } }
                    }
                    else -> readFully(rawStream, actualLen.toInt())
                }
            }.onFailure { e ->
                if (connected.get()) {
                    connected.set(false)
                    mainHandler.post { listener.onError("Read error: ${e.message}") }
                }
                return
            }
        }
    }

    private fun readFully(stream: java.io.InputStream, length: Int): ByteArray {
        if (length == 0) return ByteArray(0)
        val buf = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val read = stream.read(buf, offset, length - offset)
            if (read == -1) throw java.io.EOFException("Stream ended before $length bytes read")
            offset += read
        }
        return buf
    }

    private fun encodeTextFrame(text: String): String {
        val payload = text.toByteArray(Charsets.UTF_8)
        val mask = ByteArray(4) { Random.nextInt(256).toByte() }
        val header = buildFrameHeader(0x81, payload.size, mask)
        val masked = payload.mapIndexed { i, b -> (b.toInt() xor mask[i % 4].toInt()).toByte() }.toByteArray()
        return String(header + mask + masked, Charsets.ISO_8859_1)
    }

    private fun encodePongFrame(): String {
        val header = buildFrameHeader(0x8A, 0, null)
        return String(header, Charsets.ISO_8859_1)
    }

    private fun buildFrameHeader(finOpcode: Int, length: Int, mask: ByteArray?): ByteArray {
        val maskBit = if (mask != null) 0x80 else 0
        return when {
            length < 126  -> byteArrayOf(finOpcode.toByte(), (maskBit or length).toByte())
            length < 65536 -> byteArrayOf(finOpcode.toByte(), (maskBit or 126).toByte(),
                (length shr 8).toByte(), length.toByte())
            else -> byteArrayOf(finOpcode.toByte(), (maskBit or 127).toByte(),
                0, 0, 0, 0,
                (length shr 24).toByte(), (length shr 16).toByte(),
                (length shr 8).toByte(), length.toByte())
        }
    }

    private fun generateWebSocketKey(): String {
        val bytes = ByteArray(16).also { Random.nextBytes(it) }
        return Base64.getEncoder().encodeToString(bytes)
    }

    private fun computeAcceptKey(key: String): String {
        val magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        val combined = (key + magic).toByteArray(Charsets.UTF_8)
        val sha1 = MessageDigest.getInstance("SHA-1").digest(combined)
        return Base64.getEncoder().encodeToString(sha1)
    }

    private fun safeClose() {
        runCatching { writerRef.getAndSet(null)?.close() }
        runCatching { socketRef.getAndSet(null)?.close() }
    }
}
