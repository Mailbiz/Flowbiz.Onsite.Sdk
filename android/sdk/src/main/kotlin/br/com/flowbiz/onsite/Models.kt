package br.com.flowbiz.onsite

/**
 * Payload value types for the typed event catalog (SPEC §5).
 *
 * Properties are camelCase; serialization emits snake_case wire keys
 * (see [EventSerializer]). Optional (`null`) fields are omitted from the
 * wire entirely — `"key": null` never appears.
 *
 * `properties` / `recoveryProperties` are free-form maps passed through to
 * the wire as-is (keys are not case-converted). Supported value types:
 * `String`, `Number`, `Boolean`, `List`, `Map`, `null` (null entries are
 * dropped from objects).
 */

/** User payload for `accountLogin` / `accountSync`. */
data class User(
    val userId: String,
    val email: String,
    val phone: String? = null,
    val name: String? = null,
    val plan: String? = null,
    val createdAt: String? = null,
)

/** A purchasable variant of a [Product]. */
data class ProductVariant(
    val sku: String,
    val price: Double,
    val name: String? = null,
    val url: String? = null,
    val imageUrl: String? = null,
    val priceFrom: Double? = null,
    val stock: Int? = null,
    val available: Boolean? = null,
    val properties: Map<String, Any?>? = null,
    val recoveryProperties: Map<String, Any?>? = null,
)

/** Product payload for `productView`. */
data class Product(
    val productId: String,
    val url: String? = null,
    val category: String? = null,
    val brand: String? = null,
    val variants: List<ProductVariant>,
)

/** A line item inside a [Cart], `addToCart` or an [Order]. */
data class CartItem(
    val productId: String,
    val sku: String,
    val quantity: Int,
    val price: Double,
    val name: String? = null,
    val priceFrom: Double? = null,
    val category: String? = null,
    val brand: String? = null,
    val url: String? = null,
    val imageUrl: String? = null,
    val properties: Map<String, Any?>? = null,
    val recoveryProperties: Map<String, Any?>? = null,
)

/** Delivery address for [Cart] / [Order]. */
data class Address(
    val postalCode: String? = null,
    val addressLine1: String? = null,
    val addressNumber: String? = null,
    val addressLine2: String? = null,
    val city: String? = null,
    val state: String? = null,
    val country: String? = null,
    val neighborhood: String? = null,
)

/** Cart payload for `cartSync`. An empty-items cart is valid and always sent (SPEC §7). */
data class Cart(
    val cartId: String,
    val subtotal: Double,
    val total: Double,
    val freight: Double,
    val tax: Double,
    val discounts: Double,
    val currency: String? = null,
    val coupons: List<String>? = null,
    val items: List<CartItem>? = null,
    val deliveryAddress: Address? = null,
)

/** Checkout progress payload for `checkoutStep`. */
data class Checkout(
    val cartId: String,
    val step: Int,
    val totalSteps: Int,
    val stepName: String,
)

/** A payment method entry on an [Order]. */
data class PaymentMethod(
    val type: String,
    val amount: Double,
)

/** A delivery method entry on an [Order]. */
data class DeliveryMethod(
    val type: String,
    val amount: Double,
)

/** Order payload for `orderComplete`. */
data class Order(
    val cartId: String,
    val orderId: String? = null,
    val subtotal: Double,
    val total: Double,
    val freight: Double,
    val tax: Double,
    val discounts: Double,
    val currency: String? = null,
    val coupons: List<String>? = null,
    val items: List<CartItem>? = null,
    val deliveryAddress: Address? = null,
    val paymentMethods: List<PaymentMethod>? = null,
    val deliveryMethods: List<DeliveryMethod>? = null,
)
