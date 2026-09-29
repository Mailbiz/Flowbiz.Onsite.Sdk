package br.com.flowbiz.onsite

/**
 * A decoded cart-recovery link, returned by [Flowbiz.handleLink]. The app
 * restores the cart however it wants; the SDK does not adopt [userId] as its
 * identity.
 */
data class RecoveryPayload(
    val cartId: String,
    val userId: String,
    val products: List<RecoveryProduct>,
)

/**
 * One recovered cart line, with the web `buildCartRecoveryPayload` fallbacks:
 * an unparseable *or* `0` [quantity] becomes 1 (`parseInt(it[0]) || 1`),
 * missing ids become `""`, and absent or unparseable [recoveryProperties]
 * are null (the web's `{}`).
 */
data class RecoveryProduct(
    val productId: String,
    val sku: String,
    val quantity: Int,
    val recoveryProperties: Map<String, Any?>? = null,
)
