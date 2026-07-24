package com.flowbiz.onsite

import java.net.HttpURLConnection
import java.net.URL

/**
 * Outcome of one `POST /collect` attempt, per the SPEC §9 response table.
 * Batch-level: the collector accepts or rejects the whole request.
 */
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
 * Transport seam: posts one already-serialized `{"data":[...]}` body.
 * Implementations never throw; every failure maps to a [SendResult]
 * (SPEC §3). Blocking by design — always called on the SDK's serial
 * scheduler thread, never the caller's (SPEC §3).
 */
internal interface HttpSender {
    fun send(body: String): SendResult
}

/**
 * Production [HttpSender] over [HttpURLConnection] (SPEC §1): POST
 * `{collectorUrl}/collect`, `Content-Type: application/json`, `platform`
 * header, 5 s connect / 10 s read timeout.
 *
 * Classification (SPEC §9), see [classify]:
 * - 2xx → [SendResult.SUCCESS]
 * - **3xx → [SendResult.PERMANENT_ERROR]** — SPEC only says 3xx is "not
 *   success". Redirects are disabled (`instanceFollowRedirects = false`) so
 *   3xx is observed honestly; a redirecting collector URL is a
 *   misconfiguration that retrying can never fix, so treating it as
 *   retriable would loop the batch forever. Deliberate, flagged for review.
 * - 413 → [SendResult.PAYLOAD_TOO_LARGE]
 * - 408/429 → [SendResult.RETRIABLE_ERROR]
 * - other 4xx → [SendResult.PERMANENT_ERROR]
 * - 5xx, unrecognized codes, timeouts, I/O errors → [SendResult.RETRIABLE_ERROR]
 *
 * A malformed [collectorUrl] makes every send a [SendResult.PERMANENT_ERROR]
 * (nothing can ever be delivered; the queue must not grow forever). Config
 * validation proper happens in Slice 4.
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
        /** SPEC §2/§9: 5 s connection timeout — internal constant. */
        const val CONNECT_TIMEOUT_MS = 5_000

        /** Read timeout; the collector answers small JSON bodies fast. */
        const val READ_TIMEOUT_MS = 10_000

        /** Status-code → [SendResult] mapping (SPEC §9 table); pure, test-pinned. */
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
