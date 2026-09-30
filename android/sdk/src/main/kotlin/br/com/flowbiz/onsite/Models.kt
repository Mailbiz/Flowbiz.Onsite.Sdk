package br.com.flowbiz.onsite

data class User(
    val userId: String,
    val email: String,
    val phone: String? = null,
    val name: String? = null,
    val plan: String? = null,
    val createdAt: String? = null,
)

data class ProductVariant(
    val sku: String,
    val price: Double,
    val name: String? = null,
    val url: String? = null,
    val imageUrl: String? = null,
    val priceFrom: Double? = null,
    val stock: Int? = null,
    val available: Boolean? = null,
    /** Keys ship as-is; values: String, Number, Boolean, List, Map or null (null map values are dropped). */
    val properties: Map<String, Any?>? = null,
    val recoveryProperties: Map<String, Any?>? = null,
)

data class Product(
    val productId: String,
    val url: String? = null,
    val category: String? = null,
    val brand: String? = null,
    val variants: List<ProductVariant>,
)

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
    /** Keys ship as-is; values: String, Number, Boolean, List, Map or null (null map values are dropped). */
    val properties: Map<String, Any?>? = null,
    val recoveryProperties: Map<String, Any?>? = null,
)

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

/** Unlike on web, an empty cart is still sent: emptying a cart is signal. */
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

data class Checkout(
    val cartId: String,
    val step: Int,
    val totalSteps: Int,
    val stepName: String,
)

data class PaymentMethod(
    val type: String,
    val amount: Double,
)

data class DeliveryMethod(
    val type: String,
    val amount: Double,
)

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
