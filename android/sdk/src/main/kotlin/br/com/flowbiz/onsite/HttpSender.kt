package br.com.flowbiz.onsite

import java.net.HttpURLConnection
import java.net.URL

/** Outcome of one `POST /collect` attempt; the collector accepts or rejects the whole batch. */
internal enum class SendResult {
    /** 2xx — the batch was ingested; dequeue it. */
    SUCCESS,

    /** 5xx / 408 / 429 / timeout / network error — keep queued, back off. */
    RETRIABLE_ERROR,

    /** 4xx (except 408/429/413) and 3xx — retrying cannot help; drop (after bisection). */
    PERMANENT_ERROR,

    /** 413 — the batch is too large; split and retry the halves. */
    PAYLOAD_TOO_LARGE,
}

/**
 * Posts one serialized `{"data":[...]}` body. Blocking by design: always
 * called on the SDK's scheduler thread. Never throws; every failure maps to
 * a [SendResult].
 */
internal interface HttpSender {
    fun send(body: String): SendResult
}

/**
 * `POST {collectorUrl}/collect` with the `platform` header. Redirects are not
 * followed and a 3xx is permanent: a redirect means the batch was not
 * ingested, and a redirecting collector URL is a misconfiguration that
 * retrying can never fix, so a retriable 3xx would loop the batch forever.
 * A malformed [collectorUrl] makes every send permanent for the same reason.
 */
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
        val url = endpoint ?: return SendResult.PERMANENT_ERROR
        var connection: HttpURLConnection? = null
        return try {
            connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false // observe 3xx, never follow
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

        /** Read timeout; the collector answers small JSON bodies fast. */
        const val READ_TIMEOUT_MS = 10_000

        fun classify(code: Int): SendResult = when {
            code in 200..299 -> SendResult.SUCCESS
            code in 300..399 -> SendResult.PERMANENT_ERROR // misconfig; see class doc
            code == 413 -> SendResult.PAYLOAD_TOO_LARGE
            code == 408 || code == 429 -> SendResult.RETRIABLE_ERROR
            code in 400..499 -> SendResult.PERMANENT_ERROR
            else -> SendResult.RETRIABLE_ERROR // 5xx and anything unexpected
        }
    }
}
