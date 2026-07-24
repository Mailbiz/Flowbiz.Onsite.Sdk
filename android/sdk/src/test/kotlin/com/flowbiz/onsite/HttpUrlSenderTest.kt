package com.flowbiz.onsite

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * SPEC §9 response classification through a real socket plus the pure
 * [HttpUrlSender.classify] table. Also pins the wire mechanics: POST to
 * `/collect`, JSON content type, `platform` header, body passthrough,
 * redirects not followed.
 *
 * Uses a minimal [ServerSocket]-based HTTP stub: `com.sun.net.httpserver`
 * is not on the Android unit-test compile classpath (tests compile against
 * `android.jar`, same reason org.json is a test dependency).
 */
class HttpUrlSenderTest {

    /** One-shot loopback HTTP server answering every request with [status]. */
    private class StubServer(
        private val status: Int,
        private val delayMillis: Long = 0,
        private val extraHeaders: Map<String, String> = emptyMap(),
    ) : AutoCloseable {

        @Volatile var method: String? = null
        @Volatile var path: String? = null
        @Volatile var contentType: String? = null
        @Volatile var platform: String? = null
        @Volatile var body: String? = null

        private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val baseUrl = "http://127.0.0.1:${socket.localPort}"

        private val thread = Thread {
            try {
                while (true) {
                    socket.accept().use { handle(it) }
                }
            } catch (_: Throwable) {
                // Server socket closed — test over.
            }
        }.apply {
            isDaemon = true
            start()
        }

        private fun handle(client: Socket) {
            val input = client.getInputStream()
            val requestLine = readLine(input) ?: return
            val parts = requestLine.split(" ")
            method = parts.getOrNull(0)
            path = parts.getOrNull(1)
            var contentLength = 0
            while (true) {
                val line = readLine(input) ?: break
                if (line.isEmpty()) break
                val name = line.substringBefore(':').trim().lowercase()
                val value = line.substringAfter(':').trim()
                when (name) {
                    "content-type" -> contentType = value
                    "platform" -> platform = value
                    "content-length" -> contentLength = value.toIntOrNull() ?: 0
                }
            }
            val bodyBytes = ByteArray(contentLength)
            var read = 0
            while (read < contentLength) {
                val n = input.read(bodyBytes, read, contentLength - read)
                if (n < 0) break
                read += n
            }
            body = String(bodyBytes, 0, read, Charsets.UTF_8)

            if (delayMillis > 0) Thread.sleep(delayMillis)

            val responseBody = if (status == 200) "{}".toByteArray() else ByteArray(0)
            val out: OutputStream = client.getOutputStream()
            val headers = buildString {
                append("HTTP/1.1 $status Stub\r\n")
                extraHeaders.forEach { (k, v) -> append("$k: $v\r\n") }
                if (status != 204) append("Content-Length: ${responseBody.size}\r\n")
                append("Connection: close\r\n\r\n")
            }
            out.write(headers.toByteArray(Charsets.ISO_8859_1))
            out.write(responseBody)
            out.flush()
        }

        private fun readLine(input: InputStream): String? {
            val buffer = StringBuilder()
            while (true) {
                val c = input.read()
                if (c < 0) return if (buffer.isEmpty()) null else buffer.toString()
                if (c == '\n'.code) return buffer.toString().removeSuffix("\r")
                buffer.append(c.toChar())
            }
        }

        override fun close() {
            socket.close()
        }
    }

    private var server: StubServer? = null

    private fun startServer(
        status: Int,
        delayMillis: Long = 0,
        headers: Map<String, String> = emptyMap(),
    ): StubServer = StubServer(status, delayMillis, headers).also { server = it }

    @After
    fun tearDown() {
        server?.close()
    }

    private fun sendTo(baseUrl: String): SendResult =
        HttpUrlSender(baseUrl, "android").send("""{"data":[]}""")

    // --- Wire mechanics ---

    @Test
    fun postsJsonBodyWithPlatformHeaderToCollectPath() {
        val stub = startServer(200)
        // Trailing slash on the configured URL must not double up.
        val result = HttpUrlSender(stub.baseUrl + "/", "android").send("""{"data":[{"event":"e1"}]}""")
        assertEquals(SendResult.SUCCESS, result)
        assertEquals("POST", stub.method)
        assertEquals("/collect", stub.path)
        assertEquals("application/json", stub.contentType)
        assertEquals("android", stub.platform)
        assertEquals("""{"data":[{"event":"e1"}]}""", stub.body)
    }

    // --- Real-socket classification ---

    @Test
    fun http200IsSuccess() {
        assertEquals(SendResult.SUCCESS, sendTo(startServer(200).baseUrl))
    }

    @Test
    fun http204IsSuccess() {
        assertEquals(SendResult.SUCCESS, sendTo(startServer(204).baseUrl))
    }

    @Test
    fun http302IsPermanentAndNotFollowed() {
        val stub = startServer(302, headers = mapOf("Location" to "http://127.0.0.1:1/elsewhere"))
        assertEquals(SendResult.PERMANENT_ERROR, sendTo(stub.baseUrl))
        // The redirect target (a dead port) was never contacted — the 302
        // itself was observed and classified.
        assertEquals("/collect", stub.path)
    }

    @Test
    fun http400IsPermanent() {
        assertEquals(SendResult.PERMANENT_ERROR, sendTo(startServer(400).baseUrl))
    }

    @Test
    fun http408IsRetriable() {
        assertEquals(SendResult.RETRIABLE_ERROR, sendTo(startServer(408).baseUrl))
    }

    @Test
    fun http413IsPayloadTooLarge() {
        assertEquals(SendResult.PAYLOAD_TOO_LARGE, sendTo(startServer(413).baseUrl))
    }

    @Test
    fun http429IsRetriable() {
        assertEquals(SendResult.RETRIABLE_ERROR, sendTo(startServer(429).baseUrl))
    }

    @Test
    fun http500IsRetriable() {
        assertEquals(SendResult.RETRIABLE_ERROR, sendTo(startServer(500).baseUrl))
    }

    @Test
    fun readTimeoutIsRetriable() {
        val stub = startServer(200, delayMillis = 2_000)
        val sender = HttpUrlSender(stub.baseUrl, "android", readTimeoutMillis = 100)
        assertEquals(SendResult.RETRIABLE_ERROR, sender.send("""{"data":[]}"""))
    }

    @Test
    fun connectionRefusedIsRetriable() {
        // Grab a genuinely free port, then close it — nothing listens there.
        val port = ServerSocket(0).use { it.localPort }
        val sender = HttpUrlSender("http://127.0.0.1:$port", "android", connectTimeoutMillis = 500)
        assertEquals(SendResult.RETRIABLE_ERROR, sender.send("""{"data":[]}"""))
    }

    @Test
    fun malformedCollectorUrlIsPermanent() {
        assertEquals(SendResult.PERMANENT_ERROR, HttpUrlSender("nonsense://::bad::", "android").send("{}"))
    }

    // --- Pure classification table (SPEC §9) ---

    @Test
    fun classificationTable() {
        val cases = mapOf(
            200 to SendResult.SUCCESS,
            201 to SendResult.SUCCESS,
            204 to SendResult.SUCCESS,
            299 to SendResult.SUCCESS,
            301 to SendResult.PERMANENT_ERROR,
            302 to SendResult.PERMANENT_ERROR,
            308 to SendResult.PERMANENT_ERROR,
            400 to SendResult.PERMANENT_ERROR,
            401 to SendResult.PERMANENT_ERROR,
            403 to SendResult.PERMANENT_ERROR,
            404 to SendResult.PERMANENT_ERROR,
            408 to SendResult.RETRIABLE_ERROR,
            410 to SendResult.PERMANENT_ERROR,
            413 to SendResult.PAYLOAD_TOO_LARGE,
            422 to SendResult.PERMANENT_ERROR,
            429 to SendResult.RETRIABLE_ERROR,
            500 to SendResult.RETRIABLE_ERROR,
            502 to SendResult.RETRIABLE_ERROR,
            503 to SendResult.RETRIABLE_ERROR,
            599 to SendResult.RETRIABLE_ERROR,
            100 to SendResult.RETRIABLE_ERROR, // unexpected → keep and retry
            -1 to SendResult.RETRIABLE_ERROR, // HttpURLConnection "no valid code"
        )
        for ((code, expected) in cases) {
            assertEquals("status $code", expected, HttpUrlSender.classify(code))
        }
    }
}
