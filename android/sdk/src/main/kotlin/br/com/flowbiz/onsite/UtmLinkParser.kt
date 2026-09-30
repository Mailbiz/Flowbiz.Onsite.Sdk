package br.com.flowbiz.onsite

// Port of the web tag's `Url.getQueryParameters` + `setUtmNavigationContext`, quirks included (vectors.json).
internal object UtmLinkParser {

    val ALLOWLIST = listOf(
        "utm_source",
        "utm_medium",
        "utm_campaign",
        "utm_journey",
        "utm_journey_channel",
        "utm_journey_type",
        "utm_step_id",
        "utm_journey_version",
        "utm_journey_instance",
    )

    private val FLOW_PARAMS_KEYS = listOf("utm_step_id", "utm_journey_version", "utm_journey_instance")

    fun extract(url: String): Map<String, String> {
        val params = queryParameters(url)
        return buildMap { for (key in ALLOWLIST) params[key]?.takeIf { it.isNotEmpty() }?.let { put(key, it) } }
    }

    private fun queryParameters(url: String): Map<String, String> {
        val query = url.split('?').getOrNull(1)?.substringBefore("/#")?.substringBefore('#') ?: return emptyMap()
        val params = HashMap<String, String>()
        for (pair in query.split('&')) {
            val parts = pair.split('=')
            val key = parts[0]
            if (key.isEmpty()) continue
            val value = parts.getOrNull(1)?.let(::decodeURIComponentOrRaw) ?: "undefined"
            if (key == "utm_flow_params") {
                value.split('|').take(3).forEachIndexed { i, part -> params[FLOW_PARAMS_KEYS[i]] = part }
            } else {
                params[key] = value
            }
        }
        return params
    }

    // Hand-rolled: URLDecoder turns `+` into a space and Uri.decode swaps bad UTF-8 for U+FFFD.
    fun decodeURIComponentOrRaw(value: String): String {
        if ('%' !in value) return value
        val out = StringBuilder(value.length)
        var i = 0
        while (i < value.length) {
            if (value[i] != '%') {
                out.append(value[i++])
                continue
            }
            val lead = escapedByte(value, i) ?: return value
            val size = when (lead) {
                in 0x00..0x7F -> 1
                in 0xC0..0xDF -> 2
                in 0xE0..0xEF -> 3
                in 0xF0..0xF7 -> 4
                else -> return value
            }
            var codePoint = if (size == 1) lead else lead and (0x7F shr size)
            for (k in 1 until size) {
                val next = escapedByte(value, i + 3 * k)?.takeIf { (it and 0xC0) == 0x80 } ?: return value
                codePoint = (codePoint shl 6) or (next and 0x3F)
            }
            if (codePoint < MIN_CODE_POINT[size] || codePoint > 0x10FFFF || codePoint in 0xD800..0xDFFF) return value
            out.appendCodePoint(codePoint)
            i += 3 * size
        }
        return out.toString()
    }

    private val MIN_CODE_POINT = intArrayOf(0, 0, 0x80, 0x800, 0x10000)

    private fun escapedByte(value: String, at: Int): Int? {
        if (at + 2 >= value.length || value[at] != '%') return null
        val hex = value.substring(at + 1, at + 3)
        // Checked first: toInt(16) alone also takes a sign or non-ASCII digits.
        return if (hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) hex.toInt(16) else null
    }
}
