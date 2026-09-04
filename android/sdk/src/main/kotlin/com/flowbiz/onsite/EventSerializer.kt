package com.flowbiz.onsite

import org.json.JSONArray
import org.json.JSONObject

/**
 * Event → wire serialization (SPEC §5).
 *
 * Maps a typed [Event] to its wire event name and its `data` payload JSON
 * string: snake_case keys, optional (`null`) fields omitted entirely.
 * Free-form `properties` / `recoveryProperties` maps are passed through with
 * their keys untouched; `null` values inside those maps are dropped (inside
 * arrays a `null` element is kept as JSON `null` to preserve positions).
 *
 * Must stay behaviorally identical to the Swift `EventSerializer` — both are
 * pinned by the shared fixtures in `shared/fixtures/`. The produced wire
 * string is rendered by [CanonicalJson] (sorted keys, `JSON.stringify`
 * number rendering and escaping) and is byte-identical across platforms.
 *
 * Garbage-input contract (aligned with Swift): serialization **throws** on
 * non-finite numbers (NaN/±Infinity) — org.json throws `JSONException` when
 * the value enters the tree; the Swift writer throws its own error for the
 * same input. SPEC §3's never-throw boundary is applied at the public API in
 * Slice 4; internally serialization is strict.
 */
internal object EventSerializer {

    /** Wire event name (SPEC §5 table). */
    fun wireName(event: Event): String = when (event) {
        is Event.PageView -> "page.view"
        is Event.AccountLogin -> "account.login"
        is Event.AccountSync -> "account.sync"
        is Event.ProductView -> "product.view"
        is Event.CartSync -> "cart.sync"
        is Event.AddToCart -> "cart.add"
        is Event.CartItemUpdate -> "cart.item.update"
        is Event.CartSetPostalCode -> "cart.setpostalcode"
        is Event.CartSetCoupon -> "cart.setcoupon"
        is Event.CheckoutStep -> "checkout.step"
        is Event.OrderComplete -> "order.complete"
        is Event.OrderCancel -> "order.cancel"
    }

    /**
     * The envelope `data` field value: the payload as a canonical JSON string
     * (see [CanonicalJson]). Throws only for non-finite numbers.
     */
    fun dataJson(event: Event, baseUri: String? = null): String = CanonicalJson.render(dataObject(event, baseUri))

    /** The payload as a JSON object (snake_case keys, nulls omitted). */
    fun dataObject(event: Event, baseUri: String? = null): JSONObject = when (event) {
        is Event.PageView -> JSONObject().put("page", pageObject(event, baseUri))
        is Event.AccountLogin -> JSONObject().put("user", userObject(event.user))
        is Event.AccountSync -> JSONObject().put("user", userObject(event.user))
        is Event.ProductView -> JSONObject().put("product", productObject(event.product, baseUri))
        is Event.CartSync -> JSONObject().put("cart", cartObject(event.cart, baseUri))
        is Event.AddToCart -> JSONObject().put("products", JSONArray(event.products.map { cartItemObject(it, baseUri) }))
        is Event.CartItemUpdate -> JSONObject()
            .put("cart_id", event.cartId)
            .put("product_id", event.productId)
            .put("sku", event.sku)
            .put("quantity", event.quantity)
        is Event.CartSetPostalCode -> JSONObject()
            .put("cart_id", event.cartId)
            .put("postal_code", event.postalCode)
        is Event.CartSetCoupon -> JSONObject()
            .put("cart_id", event.cartId)
            .put("coupon", event.coupon)
        is Event.CheckoutStep -> JSONObject().put("checkout", checkoutObject(event.checkout))
        is Event.OrderComplete -> JSONObject().put("order", orderObject(event.order, baseUri))
        is Event.OrderCancel -> JSONObject()
            .putIfPresent("order_id", event.orderId)
            .putIfPresent("cart_id", event.cartId)
    }

    private fun pageObject(event: Event.PageView, baseUri: String?): JSONObject = JSONObject()
        .putIfPresent("title", event.title)
        .putIfPresent("url", UrlResolver.resolve(event.path, baseUri))

    private fun userObject(user: User): JSONObject = JSONObject()
        .put("user_id", user.userId)
        .put("email", user.email)
        .putIfPresent("phone", user.phone)
        .putIfPresent("name", user.name)
        .putIfPresent("plan", user.plan)
        .putIfPresent("created_at", user.createdAt)

    private fun productObject(product: Product, baseUri: String?): JSONObject = JSONObject()
        .put("product_id", product.productId)
        .putIfPresent("url", UrlResolver.resolve(product.url, baseUri))
        .putIfPresent("category", product.category)
        .putIfPresent("brand", product.brand)
        .put("variants", JSONArray(product.variants.map { variantObject(it, baseUri) }))

    private fun variantObject(variant: ProductVariant, baseUri: String?): JSONObject = JSONObject()
        .put("sku", variant.sku)
        .put("price", variant.price)
        .putIfPresent("name", variant.name)
        .putIfPresent("url", UrlResolver.resolve(variant.url, baseUri))
        .putIfPresent("image_url", UrlResolver.resolve(variant.imageUrl, baseUri))
        .putIfPresent("price_from", variant.priceFrom)
        .putIfPresent("stock", variant.stock)
        .putIfPresent("available", variant.available)
        .putIfPresent("properties", variant.properties?.let { freeFormObject(it) })
        .putIfPresent("recovery_properties", variant.recoveryProperties?.let { freeFormObject(it) })

    private fun cartItemObject(item: CartItem, baseUri: String?): JSONObject = JSONObject()
        .put("product_id", item.productId)
        .put("sku", item.sku)
        .put("quantity", item.quantity)
        .put("price", item.price)
        .putIfPresent("name", item.name)
        .putIfPresent("price_from", item.priceFrom)
        .putIfPresent("category", item.category)
        .putIfPresent("brand", item.brand)
        .putIfPresent("url", UrlResolver.resolve(item.url, baseUri))
        .putIfPresent("image_url", UrlResolver.resolve(item.imageUrl, baseUri))
        .putIfPresent("properties", item.properties?.let { freeFormObject(it) })
        .putIfPresent("recovery_properties", item.recoveryProperties?.let { freeFormObject(it) })

    private fun addressObject(address: Address): JSONObject = JSONObject()
        .putIfPresent("postal_code", address.postalCode)
        .putIfPresent("address_line1", address.addressLine1)
        .putIfPresent("address_number", address.addressNumber)
        .putIfPresent("address_line2", address.addressLine2)
        .putIfPresent("city", address.city)
        .putIfPresent("state", address.state)
        .putIfPresent("country", address.country)
        .putIfPresent("neighborhood", address.neighborhood)

    private fun cartObject(cart: Cart, baseUri: String?): JSONObject = JSONObject()
        .put("cart_id", cart.cartId)
        .put("subtotal", cart.subtotal)
        .put("total", cart.total)
        .put("freight", cart.freight)
        .put("tax", cart.tax)
        .put("discounts", cart.discounts)
        .putIfPresent("currency", cart.currency)
        .putIfPresent("coupons", cart.coupons?.let { JSONArray(it) })
        .putIfPresent("items", cart.items?.let { items -> JSONArray(items.map { cartItemObject(it, baseUri) }) })
        .putIfPresent("delivery_address", cart.deliveryAddress?.let { addressObject(it) })

    private fun checkoutObject(checkout: Checkout): JSONObject = JSONObject()
        .put("cart_id", checkout.cartId)
        .put("step", checkout.step)
        .put("total_steps", checkout.totalSteps)
        .put("step_name", checkout.stepName)

    private fun orderObject(order: Order, baseUri: String?): JSONObject = JSONObject()
        .put("cart_id", order.cartId)
        .putIfPresent("order_id", order.orderId)
        .put("subtotal", order.subtotal)
        .put("total", order.total)
        .put("freight", order.freight)
        .put("tax", order.tax)
        .put("discounts", order.discounts)
        .putIfPresent("currency", order.currency)
        .putIfPresent("coupons", order.coupons?.let { JSONArray(it) })
        .putIfPresent("items", order.items?.let { items -> JSONArray(items.map { cartItemObject(it, baseUri) }) })
        .putIfPresent("delivery_address", order.deliveryAddress?.let { addressObject(it) })
        .putIfPresent("payment_methods", order.paymentMethods?.let { methods ->
            JSONArray(methods.map { JSONObject().put("type", it.type).put("amount", it.amount) })
        })
        .putIfPresent("delivery_methods", order.deliveryMethods?.let { methods ->
            JSONArray(methods.map { JSONObject().put("type", it.type).put("amount", it.amount) })
        })

    /** Puts [value] only when non-null; nulls are omitted entirely from the wire. */
    private fun JSONObject.putIfPresent(key: String, value: Any?): JSONObject {
        if (value != null) put(key, wrapValue(value))
        return this
    }

    /** Free-form `properties` / `recovery_properties`: keys untouched, null entries dropped. */
    private fun freeFormObject(map: Map<*, *>): JSONObject {
        val obj = JSONObject()
        for ((key, value) in map) {
            if (key == null || value == null) continue
            obj.put(key.toString(), wrapValue(value))
        }
        return obj
    }

    /** Recursively converts Kotlin values to org.json values. */
    private fun wrapValue(value: Any): Any = when (value) {
        is JSONObject, is JSONArray -> value
        is Map<*, *> -> freeFormObject(value)
        is Collection<*> -> {
            val array = JSONArray()
            for (element in value) {
                array.put(if (element == null) JSONObject.NULL else wrapValue(element))
            }
            array
        }
        is String, is Boolean, is Number -> value
        else -> value.toString()
    }
}
