package br.com.flowbiz.onsite

/**
 * An event for [Flowbiz.track]. Payloads are sent as given: unlike the web
 * tag there is no runtime schema validation and no field enrichment, and
 * null optional fields are omitted from the wire.
 */
sealed class Event {

    /**
     * `page.view` — [path] is resolved against `FlowbizConfig.baseUri` into
     * `page.url` and the remembered `context.url`; [title] ships as
     * `page.title`. Both optional.
     */
    data class PageView(val path: String? = null, val title: String? = null) : Event()

    /** `account.login`; this and later events carry [User.userId] as `identity.user_id` until logout. */
    data class AccountLogin(val user: User) : Event()

    /** `account.sync`; this and later events carry [User.userId] as `identity.user_id` until logout. */
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
