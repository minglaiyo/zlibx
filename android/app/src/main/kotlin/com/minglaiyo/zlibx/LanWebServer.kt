// The LAN web service's HTTP server, in native Kotlin.
//
// Why this exists: the Dart `HttpServer` (a single 0.0.0.0 socket and
// then one socket per detected address, ports 8080 and 8888) served
// loopback fine but never accepted a connection from another device
// on this phone, while Legado — a native Android app — serves the
// same phone without trouble. The one variable never changed in any
// attempt was the Dart socket itself, so the transport moved here.
// Dart keeps everything else: the snapshot, the HTML pages, routing,
// Range parsing, TXT→EPUB conversion and the reader routes. This file
// only owns sockets and bytes.
//
// Contract with Dart (MethodChannel "zlibx/web_server"):
//  * Dart → native: `start` {port: int, addresses: [String]} → the
//    port actually bound (int); `stop` {} → null.
//  * Native → Dart: `handleRequest` {method: String, path: String,
//    headers: Map<String, String>} → {status: int,
//    headers: Map<String, String>, body: Uint8List?,
//    filePath: String?, fileStart: int?, fileEnd: int?}.
//    `filePath` with an inclusive [fileStart, fileEnd] range is
//    streamed from disk by this side; `body` is sent as-is. Dart
//    sets Content-Length (and Content-Range for 206) in `headers`.
//    Every request is answered with `Connection: close`: one request
//    per connection, no keep-alive — the clients here are browsers
//    and e-readers, and it keeps this server small and obviously
//    correct.
//
// Threading (the risky part, read carefully):
//  * one accept thread per bound socket; one thread per connection.
//  * a connection thread NEVER calls the MethodChannel directly: it
//    posts the `handleRequest` call to the main thread (platform
//    channels must be used there) and blocks on a CountDownLatch with
//    a 10 s timeout. On timeout, on a Dart error, or on a missing
//    reply, the connection gets a plain 500 and the socket is closed.
//  * the main thread is never blocked: it only posts the call and
//    returns. Dart answers asynchronously on its own thread.
//  * `stop()` closes every server socket (accept() then throws and
//    the accept threads exit) and every open client socket.
package com.minglaiyo.zlibx

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.nio.charset.StandardCharsets
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class LanWebServer(private val channel: MethodChannel) {

    companion object {
        private const val TAG = "ZlibxWebServer"

        /// How long a connection thread waits for Dart's answer.
        private const val HANDLE_TIMEOUT_MS = 10_000L

        /// A client that connects and sends nothing must not hold a
        /// thread forever.
        private const val SOCKET_TIMEOUT_MS = 10_000

        private const val BACKLOG = 16
        private const val BUFFER_SIZE = 64 * 1024
        private const val MAX_REQUEST_LINE_CHARS = 8 * 1024
        private const val MAX_HEADER_LINES = 100
        private const val MAX_HEADER_CHARS = 64 * 1024

        private val REASONS = mapOf(
            200 to "OK",
            206 to "Partial Content",
            400 to "Bad Request",
            404 to "Not Found",
            405 to "Method Not Allowed",
            416 to "Range Not Satisfiable",
            422 to "Unprocessable Entity",
            500 to "Internal Server Error",
        )
    }

    private data class DartResponse(
        val status: Int,
        val headers: Map<String, String>,
        val body: ByteArray?,
        val filePath: String?,
        val fileStart: Long?,
        val fileEnd: Long?,
    )

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var serverSockets: List<ServerSocket> = emptyList()

    @Volatile
    private var boundPort: Int = -1

    private val clientSockets =
        Collections.synchronizedSet(mutableSetOf<Socket>())

    val isRunning: Boolean
        get() = serverSockets.isNotEmpty()

    val port: Int?
        get() = if (serverSockets.isEmpty()) null else boundPort

    /// Bind and start serving. Idempotent: starting while running just
    /// returns the port already bound.
    ///
    /// Binds a single wildcard socket on `::` (IPv6 wildcard,
    /// dual-stack), exactly like Legado. Binding specific IPv4
    /// addresses creates IPv4-mapped IPv6 sockets that other devices
    /// cannot reach (visible in /proc/net/tcp6 but never accepting
    /// external connections); the `::` wildcard is what works.
    /// [addresses] is accepted for compatibility but ignored for
    /// binding; the wildcard covers every interface. Falls back to
    /// 0.0.0.0 when `::` cannot bind, and to a system-chosen port
    /// when [port] is taken.
    @Synchronized
    fun start(port: Int, addresses: List<String>): Int {
        if (serverSockets.isNotEmpty()) return boundPort
        val bound = ArrayList<ServerSocket>()
        try {
            bound.add(bindSocket(InetAddress.getByName("::"), port))
        } catch (e: IOException) {
            Log.w(TAG, "bind [::]:$port failed, trying 0.0.0.0", e)
            try {
                bound.add(bindSocket(InetAddress.getByName("0.0.0.0"), port))
            } catch (e2: IOException) {
                Log.w(TAG, "bind 0.0.0.0:$port failed, trying any port", e2)
                // Throws if this fails too: start fails, as before.
                bound.add(bindSocket(InetAddress.getByName("0.0.0.0"), 0))
            }
        }
        serverSockets = bound
        boundPort = bound.first().localPort
        for (server in bound) {
            val thread = Thread(
                { acceptLoop(server) },
                "zlibx-web-accept-${server.inetAddress.hostAddress}",
            )
            thread.isDaemon = true
            thread.start()
        }
        Log.i(TAG, "listening on port $boundPort (${bound.size} socket(s))")
        return boundPort
    }

    /// Stop serving. Safe to call when not running.
    @Synchronized
    fun stop() {
        val servers = serverSockets
        if (servers.isEmpty()) return
        serverSockets = emptyList()
        boundPort = -1
        for (server in servers) {
            try {
                server.close()
            } catch (e: IOException) {
                Log.w(TAG, "server socket close failed", e)
            }
        }
        // Closing the client sockets unblocks the connection threads;
        // the accept threads exit when accept() throws.
        val clients = synchronized(clientSockets) { clientSockets.toList() }
        for (socket in clients) {
            try {
                socket.close()
            } catch (e: IOException) {
                Log.w(TAG, "client socket close failed", e)
            }
        }
        Log.i(TAG, "stopped")
    }

    private fun bindSocket(address: InetAddress, port: Int): ServerSocket {
        val server = ServerSocket()
        // Let a stop/start cycle rebind at once instead of waiting out
        // TIME_WAIT on the old socket.
        server.reuseAddress = true
        server.bind(InetSocketAddress(address, port), BACKLOG)
        return server
    }

    private fun acceptLoop(server: ServerSocket) {
        while (!server.isClosed) {
            val socket = try {
                server.accept()
            } catch (e: SocketException) {
                // stop() closed the server: exit quietly.
                return
            } catch (e: IOException) {
                Log.w(TAG, "accept failed", e)
                continue
            }
            clientSockets.add(socket)
            val thread = Thread(
                { handleConnection(socket) },
                "zlibx-web-conn-${socket.inetAddress.hostAddress}",
            )
            thread.isDaemon = true
            thread.start()
        }
    }

    private fun handleConnection(socket: Socket) {
        try {
            socket.soTimeout = SOCKET_TIMEOUT_MS
            val input = BufferedInputStream(socket.getInputStream())
            val requestLine = try {
                readLineBounded(input, MAX_REQUEST_LINE_CHARS)
            } catch (e: IOException) {
                // Absurdly long request line, or the client stalled
                // past the read timeout: garbage either way, close.
                Log.i(TAG, "request line unreadable, closing: ${e.message}")
                return
            } ?: return // client connected and said nothing
            val parts = requestLine.split(' ')
            if (parts.size < 2) {
                writeSimple(socket, 400, "Bad Request")
                return
            }
            val method = parts[0].uppercase(java.util.Locale.ROOT)
            val target = parts[1]
            val headers = readHeaders(input)
            if (headers == null) {
                writeSimple(socket, 400, "Bad Request")
                return
            }
            val path = targetToPath(target)
            val response = askDart(method, path, headers)
            if (response == null) {
                writeSimple(socket, 500, "Internal Server Error")
                return
            }
            writeResponse(socket, method, response)
        } catch (e: IOException) {
            // Client went away mid-request: nothing to answer.
            Log.i(TAG, "connection closed: ${e.message}")
        } finally {
            clientSockets.remove(socket)
            try {
                socket.close()
            } catch (_: IOException) {
            }
        }
    }

    /// Read one CRLF-terminated line, capped at [maxChars] characters
    /// (not counting the line ending). Null on EOF before any byte.
    /// Throws [IOException] when the line runs past the cap.
    private fun readLineBounded(input: InputStream, maxChars: Int): String? {
        val sb = StringBuilder()
        var seenAny = false
        while (true) {
            val byte = input.read()
            if (byte == -1) return if (seenAny) sb.toString() else null
            seenAny = true
            if (byte == '\n'.code) break
            if (byte == '\r'.code) continue
            if (sb.length >= maxChars) throw IOException("line too long")
            // Header bytes are ASCII by definition; ISO-8859-1 maps
            // bytes 1:1, so nothing is lost before percent-decoding.
            sb.append(byte.toChar())
        }
        return sb.toString()
    }

    /// Headers until the blank line, keys lowercased (Dart looks up
    /// `range` in lowercase). Null when the headers are malformed or
    /// too big — the caller answers 400.
    private fun readHeaders(input: InputStream): Map<String, String>? {
        val headers = LinkedHashMap<String, String>()
        var totalChars = 0
        while (headers.size < MAX_HEADER_LINES) {
            val line = try {
                readLineBounded(input, MAX_REQUEST_LINE_CHARS)
            } catch (e: IOException) {
                return null
            } ?: return headers // EOF: answer with what we have
            if (line.isEmpty()) return headers
            totalChars += line.length
            if (totalChars > MAX_HEADER_CHARS) return null
            val colon = line.indexOf(':')
            if (colon <= 0) return null
            headers[line.substring(0, colon).trim().lowercase(java.util.Locale.ROOT)] =
                line.substring(colon + 1).trim()
        }
        return null // more than MAX_HEADER_LINES lines
    }

    /// The request target to the path Dart routes on: strip an
    /// absolute-form scheme+authority, drop the query string, and
    /// percent-decode as UTF-8 (`+` stays a plus in a path).
    private fun targetToPath(target: String): String {
        var path = target
        if (path.startsWith("http://", ignoreCase = true) ||
            path.startsWith("https://", ignoreCase = true)
        ) {
            val slash = path.indexOf('/', path.indexOf("://") + 3)
            path = if (slash >= 0) path.substring(slash) else "/"
        }
        val query = path.indexOf('?')
        if (query >= 0) path = path.substring(0, query)
        val fragment = path.indexOf('#')
        if (fragment >= 0) path = path.substring(0, fragment)
        if (path.isEmpty()) path = "/"
        return percentDecode(path)
    }

    private fun percentDecode(raw: String): String {
        if (!raw.contains('%')) return raw
        val bytes = ArrayList<Byte>(raw.length)
        var i = 0
        while (i < raw.length) {
            val c = raw[i]
            if (c == '%' && i + 2 < raw.length) {
                val value = raw.substring(i + 1, i + 3).toIntOrNull(16)
                if (value == null) {
                    bytes.add('%'.code.toByte())
                    i++
                } else {
                    bytes.add(value.toByte())
                    i += 3
                }
            } else {
                // A raw byte above 0x7F (a client that sent UTF-8
                // unencoded): readLineBounded widened it to a Latin-1
                // char, so the byte value is the char code itself.
                bytes.add(c.code.toByte())
                i++
            }
        }
        return String(bytes.toByteArray(), StandardCharsets.UTF_8)
    }

    /// Ask Dart for the response. Called from a connection thread:
    /// the channel call is posted to the main thread and this thread
    /// blocks on a latch until the reply arrives (or times out).
    /// Null = no usable reply (timeout, Dart error, bad shape).
    private fun askDart(
        method: String,
        path: String,
        headers: Map<String, String>,
    ): DartResponse? {
        val args = mapOf<String, Any?>(
            "method" to method,
            "path" to path,
            "headers" to headers,
        )
        val latch = CountDownLatch(1)
        var result: DartResponse? = null
        mainHandler.post {
            try {
                channel.invokeMethod(
                    "handleRequest",
                    args,
                    object : MethodChannel.Result {
                        override fun success(reply: Any?) {
                            result = parseDartResponse(reply)
                            latch.countDown()
                        }

                        override fun error(
                            code: String,
                            message: String?,
                            details: Any?,
                        ) {
                            Log.w(TAG, "handleRequest error $code: $message")
                            latch.countDown()
                        }

                        override fun notImplemented() {
                            Log.w(TAG, "handleRequest not implemented")
                            latch.countDown()
                        }
                    },
                )
            } catch (e: Exception) {
                Log.w(TAG, "handleRequest invoke failed", e)
                latch.countDown()
            }
        }
        val ok = latch.await(HANDLE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        if (!ok) {
            Log.w(TAG, "handleRequest timed out after ${HANDLE_TIMEOUT_MS}ms")
        }
        return if (ok) result else null
    }

    private fun parseDartResponse(reply: Any?): DartResponse? {
        val map = reply as? Map<*, *> ?: return null
        val status = (map["status"] as? Number)?.toInt() ?: return null
        val rawHeaders = map["headers"] as? Map<*, *>
        val headers = LinkedHashMap<String, String>()
        rawHeaders?.forEach { (key, value) ->
            if (key is String) headers[key] = value?.toString() ?: ""
        }
        return DartResponse(
            status = status,
            headers = headers,
            body = map["body"] as? ByteArray,
            filePath = map["filePath"] as? String,
            fileStart = (map["fileStart"] as? Number)?.toLong(),
            fileEnd = (map["fileEnd"] as? Number)?.toLong(),
        )
    }

    private fun writeResponse(socket: Socket, method: String, r: DartResponse) {
        val out = BufferedOutputStream(socket.getOutputStream())
        val headOnly = method == "HEAD"
        // Resolve the file BEFORE writing any header: if it vanished
        // after Dart checked, this becomes a 404 instead of a
        // half-sent 200.
        var fileStream: FileInputStream? = null
        var fileCount = 0L
        if (!headOnly && r.filePath != null) {
            try {
                val file = File(r.filePath)
                val length = file.length()
                val start = (r.fileStart ?: 0L).coerceIn(0L, length)
                val end = (r.fileEnd ?: (length - 1)).coerceIn(-1L, length - 1)
                fileCount = if (end >= start) end - start + 1 else 0
                if (fileCount > 0) {
                    fileStream = FileInputStream(file)
                    skipFully(fileStream, start)
                }
            } catch (e: IOException) {
                Log.w(TAG, "file vanished mid-request: ${r.filePath}", e)
                writeSimple(socket, 404, "Not Found")
                return
            }
        }
        try {
            val head = StringBuilder()
            head.append("HTTP/1.1 ${r.status} ${REASONS[r.status] ?: "Status"}\r\n")
            var hasConnection = false
            for ((key, value) in r.headers) {
                if (key.equals("connection", ignoreCase = true)) {
                    hasConnection = true
                }
                head.append("$key: $value\r\n")
            }
            if (!hasConnection) head.append("Connection: close\r\n")
            head.append("\r\n")
            out.write(head.toString().toByteArray(StandardCharsets.ISO_8859_1))
            if (!headOnly) {
                if (fileStream != null) {
                    copyExact(out, fileStream, fileCount)
                } else if (r.body != null) {
                    out.write(r.body)
                }
            }
            out.flush()
        } finally {
            try {
                fileStream?.close()
            } catch (_: IOException) {
            }
        }
    }

    private fun skipFully(stream: FileInputStream, bytes: Long) {
        var remaining = bytes
        while (remaining > 0) {
            val skipped = stream.skip(remaining)
            if (skipped <= 0) throw IOException("could not seek to $bytes")
            remaining -= skipped
        }
    }

    private fun copyExact(
        out: BufferedOutputStream,
        input: FileInputStream,
        bytes: Long,
    ) {
        val buffer = ByteArray(BUFFER_SIZE)
        var remaining = bytes
        while (remaining > 0) {
            val want = minOf(BUFFER_SIZE.toLong(), remaining).toInt()
            val read = input.read(buffer, 0, want)
            if (read == -1) throw IOException("file shrank mid-transfer")
            out.write(buffer, 0, read)
            remaining -= read
        }
    }

    /// A small plain-text reply for errors raised on this side, before
    /// Dart was (or could be) asked.
    private fun writeSimple(socket: Socket, status: Int, text: String) {
        try {
            val body = text.toByteArray(StandardCharsets.UTF_8)
            val out = BufferedOutputStream(socket.getOutputStream())
            val head = "HTTP/1.1 $status ${REASONS[status] ?: "Status"}\r\n" +
                "Content-Type: text/plain; charset=utf-8\r\n" +
                "Content-Length: ${body.size}\r\n" +
                "Connection: close\r\n\r\n"
            out.write(head.toByteArray(StandardCharsets.ISO_8859_1))
            out.write(body)
            out.flush()
        } catch (e: IOException) {
            Log.i(TAG, "error reply failed: ${e.message}")
        }
    }
}
