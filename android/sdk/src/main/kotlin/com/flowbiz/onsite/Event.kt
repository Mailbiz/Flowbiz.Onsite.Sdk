package com.flowbiz.onsite

/**
 * Typed event catalog — the single typed entry point of SPEC §5.
 *
 * Compile-time typing replaces the web Yup layer: there is no runtime schema
 * validation and no field enrichment. Integrators build complete typed
 * payloads; the SDK serializes them verbatim (snake_case wire keys, optional
 * fields omitted when null).
 */
sealed class Event {

    /** `page.view` — [screenName] also drives the synthetic `app://<screenName>` context URL. */
    data class PageView(val screenName: String? = null) : Event()

    /** `account.login`. */
    data class AccountLogin(val user: User) : Event()

    /** `account.sync`. */
    data class AccountSync(val user: User) : Event()

    /** `product.view`. */
    data class ProductView(val product: Product) : Event()

    /** `cart.sync`. */
    data class CartSync(val cart: Cart) : Event()

    /** `cart.add`. */
    data class AddToCart(val products: List<CartItem>) : Event()

    /** `cart.item.update`. */
    data class CartItemUpdate(
        val cartId: String,
        val productId: String,
        val sku: String,
        val quantity: Int,
    ) : Event()

    /** `cart.setpostalcode`. */
    data class CartSetPostalCode(
        val cartId: String,
        val postalCode: String,
    ) : Event()

    /** `cart.setcoupon`. */
    data class CartSetCoupon(
        val cartId: String,
        val coupon: String,
    ) : Event()

    /** `checkout.step`. */
    data class CheckoutStep(val checkout: Checkout) : Event()

    /** `order.complete`. */
    data class OrderComplete(val order: Order) : Event()

    /** `order.cancel` — at least one of [orderId] / [cartId] should be provided. */
    data class OrderCancel(
        val orderId: String? = null,
        val cartId: String? = null,
    ) : Event()
}
