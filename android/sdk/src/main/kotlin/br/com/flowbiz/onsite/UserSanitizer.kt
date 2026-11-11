package br.com.flowbiz.onsite

// The web's account pipeline: the universal vendor's userSchema lowercases, then onsite-core's
// sanitizeAccountUser drops an invalid email and a user_id that identifies nobody.
internal object UserSanitizer {

    /** The event as the web would send it, or null when an account event is left with no valid user_id or email. */
    fun sanitize(event: Event): Event? = when (event) {
        is Event.AccountLogin -> sanitize(event.user)?.let(Event::AccountLogin)
        is Event.AccountSync -> sanitize(event.user)?.let(Event::AccountSync)
        else -> event
    }

    fun sanitize(user: User): User? {
        val email = user.email?.lowercase()?.takeIf(::looksLikeEmail)
        val userId = user.userId?.lowercase()?.takeIf { isValidUserId(it) && !isEmailOtherThan(it, email) }
        if (userId == null && email == null) return null
        return user.copy(userId = userId, email = email)
    }

    /** Web `setUserId(user_id || email)`. */
    fun identityUserId(user: User): String? = user.userId ?: user.email

    private val EMAIL = Regex("[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:\\.[a-zA-Z0-9-]+)*")
    private val EMAIL_TOP_LEVEL_DOMAIN = Regex("\\.(?:[a-zA-Z]{2,}|xn--[a-zA-Z0-9-]+)\\z")
    private val USER_ID_PLACEHOLDERS = setOf("0", "-1", "null", "undefined", "none", "nan")
    private const val VTEX_APP_PRINCIPAL_PREFIX = "vrn--"

    internal fun looksLikeEmail(value: String): Boolean =
        value.indexOf('@') < value.lastIndexOf('.') && EMAIL.matches(value) && EMAIL_TOP_LEVEL_DOMAIN.containsMatchIn(value)

    private fun isValidUserId(value: String): Boolean {
        val normalized = value.trim().lowercase()
        val isMalformedEmail = value.contains('@') && !looksLikeEmail(value)
        return normalized.length > 1 && normalized !in USER_ID_PLACEHOLDERS &&
            !normalized.startsWith(VTEX_APP_PRINCIPAL_PREFIX) && !isMalformedEmail
    }

    private fun isEmailOtherThan(value: String, email: String?): Boolean =
        email != null && value.contains('@') && !value.equals(email, ignoreCase = true)
}
