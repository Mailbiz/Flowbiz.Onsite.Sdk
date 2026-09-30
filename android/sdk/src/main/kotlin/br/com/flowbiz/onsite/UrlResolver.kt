package br.com.flowbiz.onsite

internal object UrlResolver {

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
