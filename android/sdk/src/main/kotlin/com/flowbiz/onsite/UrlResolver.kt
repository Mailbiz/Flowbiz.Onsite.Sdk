package com.flowbiz.onsite

/**
 * Spec §5: resolves app-supplied URL-shaped values against the configured
 * `baseUri`. Pure. Applied by [EventSerializer] to page, product, variant and
 * cart-item URLs, and by [FlowbizCore] to the remembered page URL.
 *
 * | input | output |
 * |---|---|
 * | null / blank | null |
 * | has a scheme | unchanged |
 * | `//host/...` | `https:` + value |
 * | `/path`, base set | base + value |
 * | `path`, base set | base + `/` + value |
 * | base null/empty | unchanged |
 */
internal object UrlResolver {

    /** RFC 3986 scheme: `^[A-Za-z][A-Za-z0-9+.-]*:`. */
    private val SCHEME = Regex("^[A-Za-z][A-Za-z0-9+.-]*:")

    fun resolve(value: String?, baseUri: String?): String? {
        val trimmed = value?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
        if (SCHEME.containsMatchIn(trimmed)) return trimmed
        if (trimmed.startsWith("//")) return "https:$trimmed"
        val base = baseUri?.trim().orEmpty().trimEnd('/')
        if (base.isEmpty()) return trimmed
        return if (trimmed.startsWith("/")) base + trimmed else "$base/$trimmed"
    }
}
