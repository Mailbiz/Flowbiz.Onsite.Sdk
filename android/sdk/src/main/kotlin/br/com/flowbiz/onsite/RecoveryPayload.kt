package br.com.flowbiz.onsite

/** Restoring the cart is up to the app; the SDK does not adopt [userId] as its identity. */
data class RecoveryPayload(
    val cartId: String,
    val userId: String,
    val products: List<RecoveryProduct>,
)

/** Web fallbacks apply: a missing id is `""`, a 0 or unparseable [quantity] is 1. */
data class RecoveryProduct(
    val productId: String,
    val sku: String,
    val quantity: Int,
    val recoveryProperties: Map<String, Any?>? = null,
)
