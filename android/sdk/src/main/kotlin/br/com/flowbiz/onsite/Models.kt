package br.com.flowbiz.onsite

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
    /** Free-form: keys ship as-is; values String, Number, Boolean, List, Map or null (dropped from maps). */
    val properties: Map<String, Any?>? = null,
    /** Same rules as [properties]. */
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
    /** Free-form: keys ship as-is; values String, Number, Boolean, List, Map or null (dropped from maps). */
    val properties: Map<String, Any?>? = null,
    /** Same rules as [properties]. */
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

/** Cart payload for `cartSync`. Unlike on web, an empty cart is not suppressed: emptying a cart is signal. */
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
