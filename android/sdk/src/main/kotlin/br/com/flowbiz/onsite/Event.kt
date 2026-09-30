package br.com.flowbiz.onsite

/** Sent as given: unlike the web tag, no schema validation or field enrichment; null fields are omitted. */
sealed class Event {

    /** [path] is resolved against [FlowbizConfig.baseUri]; it becomes `context.url` from this event on. */
    data class PageView(val path: String? = null, val title: String? = null) : Event()

    /** This and later events carry [User.userId] until [Flowbiz.logout]. */
    data class AccountLogin(val user: User) : Event()

    /** This and later events carry [User.userId] until [Flowbiz.logout]. */
    data class AccountSync(val user: User) : Event()

    data class ProductView(val product: Product) : Event()

    data class CartSync(val cart: Cart) : Event()

    data class AddToCart(val products: List<CartItem>) : Event()

    data class CartItemUpdate(
        val cartId: String,
        val productId: String,
        val sku: String,
        val quantity: Int,
    ) : Event()

    data class CartSetPostalCode(
        val cartId: String,
        val postalCode: String,
    ) : Event()

    data class CartSetCoupon(
        val cartId: String,
        val coupon: String,
    ) : Event()

    data class CheckoutStep(val checkout: Checkout) : Event()

    data class OrderComplete(val order: Order) : Event()

    /** Provide at least one of [orderId] and [cartId]. */
    data class OrderCancel(
        val orderId: String? = null,
        val cartId: String? = null,
    ) : Event()
}
