package br.com.flowbiz.onsite

import java.net.HttpURLConnection
import java.net.URL

internal enum class SendResult {
    SUCCESS,
    RETRIABLE_ERROR,
    PERMANENT_ERROR,
    PAYLOAD_TOO_LARGE,
}

// Blocking by design: only ever called on the SDK's serial scheduler, never the caller's thread.
internal interface HttpSender {
    fun send(body: String): SendResult
}

internal class HttpUrlSender(
    collectorUrl: String,
    private val platform: String,
    private val connectTimeoutMillis: Int = CONNECT_TIMEOUT_MS,
    private val readTimeoutMillis: Int = READ_TIMEOUT_MS,
) : HttpSender {

    private val endpoint: URL? = try {
        URL(collectorUrl.trimEnd('/') + "/collect")
    } catch (t: Throwable) {
        SdkLog.debug("invalid collector URL: ${t.javaClass.simpleName}")
        null
    }

    override fun send(body: String): SendResult {
        // Permanent, so a malformed collectorUrl cannot grow the queue forever.
        val url = endpoint ?: return SendResult.PERMANENT_ERROR
        var connection: HttpURLConnection? = null
        return try {
            connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = connectTimeoutMillis
            connection.readTimeout = readTimeoutMillis
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("platform", platform)
            val bytes = body.toByteArray(Charsets.UTF_8)
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { it.write(bytes) }
            val code = connection.responseCode
            // Drain the response so the connection can be reused.
            try {
                (connection.errorStream ?: connection.inputStream)?.use { it.readBytes() }
            } catch (_: Throwable) {
            }
            classify(code)
        } catch (t: Throwable) {
            SdkLog.debug("collect POST failed: ${t.javaClass.simpleName}")
            SendResult.RETRIABLE_ERROR
        } finally {
            try {
                connection?.disconnect()
            } catch (_: Throwable) {
            }
        }
    }

    companion object {
        const val CONNECT_TIMEOUT_MS = 5_000

        const val READ_TIMEOUT_MS = 10_000

        fun classify(code: Int): SendResult = when {
            code in 200..299 -> SendResult.SUCCESS
            code in 300..399 -> SendResult.PERMANENT_ERROR // misconfigured collector: retrying would loop forever
            code == 413 -> SendResult.PAYLOAD_TOO_LARGE
            code == 408 || code == 429 -> SendResult.RETRIABLE_ERROR
            code in 400..499 -> SendResult.PERMANENT_ERROR
            else -> SendResult.RETRIABLE_ERROR
        }
    }
}
