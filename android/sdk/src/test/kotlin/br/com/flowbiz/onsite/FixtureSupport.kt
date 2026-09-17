package br.com.flowbiz.onsite

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Test-side helpers for the shared drift-guard fixtures (`shared/fixtures/`):
 * locating the fixture directory, mapping fixture `input` JSON onto the typed
 * constructors, and structural JSON comparison.
 */
object FixtureSupport {

    /** Walks up from the working directory until `shared/<name>` is found. */
    fun sharedDir(name: String): File {
        var dir: File? = File(System.getProperty("user.dir")!!).absoluteFile
        while (dir != null) {
            val candidate = File(dir, "shared/$name")
            if (candidate.isDirectory) return candidate
            dir = dir.parentFile
        }
        error("shared/$name not found above ${System.getProperty("user.dir")!!}")
    }

    fun fixturesDir(): File = sharedDir("fixtures")

    fun fixtureFiles(): List<File> =
        fixturesDir().listFiles { f -> f.extension == "json" }!!.sortedBy { it.name }

    /** Maps a fixture (`event` name + camelCase `input`) onto the typed constructors. */
    fun buildEvent(eventName: String, input: JSONObject): Event = when (eventName) {
        "pageView" -> Event.PageView(path = input.stringOrNull("path"), title = input.stringOrNull("title"))
        "accountLogin" -> Event.AccountLogin(user(input.getJSONObject("user")))
        "accountSync" -> Event.AccountSync(user(input.getJSONObject("user")))
        "productView" -> Event.ProductView(product(input.getJSONObject("product")))
        "cartSync" -> Event.CartSync(cart(input.getJSONObject("cart")))
        "addToCart" -> Event.AddToCart(input.getJSONArray("products").objects().map { cartItem(it) })
        "cartItemUpdate" -> Event.CartItemUpdate(
            cartId = input.getString("cartId"),
            productId = input.getString("productId"),
            sku = input.getString("sku"),
            quantity = input.getInt("quantity"),
        )
        "cartSetPostalCode" -> Event.CartSetPostalCode(
            cartId = input.getString("cartId"),
            postalCode = input.getString("postalCode"),
        )
        "cartSetCoupon" -> Event.CartSetCoupon(
            cartId = input.getString("cartId"),
            coupon = input.getString("coupon"),
        )
        "checkoutStep" -> Event.CheckoutStep(
            input.getJSONObject("checkout").let {
                Checkout(
                    cartId = it.getString("cartId"),
                    step = it.getInt("step"),
                    totalSteps = it.getInt("totalSteps"),
                    stepName = it.getString("stepName"),
                )
            }
        )
        "orderComplete" -> Event.OrderComplete(order(input.getJSONObject("order")))
        "orderCancel" -> Event.OrderCancel(
            orderId = input.stringOrNull("orderId"),
            cartId = input.stringOrNull("cartId"),
        )
        else -> error("unknown fixture event: $eventName")
    }

    private fun user(json: JSONObject) = User(
        userId = json.getString("userId"),
        email = json.getString("email"),
        phone = json.stringOrNull("phone"),
        name = json.stringOrNull("name"),
        plan = json.stringOrNull("plan"),
        createdAt = json.stringOrNull("createdAt"),
    )

    private fun product(json: JSONObject) = Product(
        productId = json.getString("productId"),
        url = json.stringOrNull("url"),
        category = json.stringOrNull("category"),
        brand = json.stringOrNull("brand"),
        variants = json.getJSONArray("variants").objects().map { variant(it) },
    )

    private fun variant(json: JSONObject) = ProductVariant(
        sku = json.getString("sku"),
        price = json.getDouble("price"),
        name = json.stringOrNull("name"),
        url = json.stringOrNull("url"),
        imageUrl = json.stringOrNull("imageUrl"),
        priceFrom = json.doubleOrNull("priceFrom"),
        stock = json.intOrNull("stock"),
        available = json.boolOrNull("available"),
        properties = json.mapOrNull("properties"),
        recoveryProperties = json.mapOrNull("recoveryProperties"),
    )

    private fun cartItem(json: JSONObject) = CartItem(
        productId = json.getString("productId"),
        sku = json.getString("sku"),
        quantity = json.getInt("quantity"),
        price = json.getDouble("price"),
        name = json.stringOrNull("name"),
        priceFrom = json.doubleOrNull("priceFrom"),
        category = json.stringOrNull("category"),
        brand = json.stringOrNull("brand"),
        url = json.stringOrNull("url"),
        imageUrl = json.stringOrNull("imageUrl"),
        properties = json.mapOrNull("properties"),
        recoveryProperties = json.mapOrNull("recoveryProperties"),
    )

    private fun address(json: JSONObject) = Address(
        postalCode = json.stringOrNull("postalCode"),
        addressLine1 = json.stringOrNull("addressLine1"),
        addressNumber = json.stringOrNull("addressNumber"),
        addressLine2 = json.stringOrNull("addressLine2"),
        city = json.stringOrNull("city"),
        state = json.stringOrNull("state"),
        country = json.stringOrNull("country"),
        neighborhood = json.stringOrNull("neighborhood"),
    )

    private fun cart(json: JSONObject) = Cart(
        cartId = json.getString("cartId"),
        subtotal = json.getDouble("subtotal"),
        total = json.getDouble("total"),
        freight = json.getDouble("freight"),
        tax = json.getDouble("tax"),
        discounts = json.getDouble("discounts"),
        currency = json.stringOrNull("currency"),
        coupons = json.optJSONArray("coupons")?.let { arr -> (0 until arr.length()).map { arr.getString(it) } },
        items = json.optJSONArray("items")?.objects()?.map { cartItem(it) },
        deliveryAddress = json.optJSONObject("deliveryAddress")?.let { address(it) },
    )

    private fun order(json: JSONObject) = Order(
        cartId = json.getString("cartId"),
        orderId = json.stringOrNull("orderId"),
        subtotal = json.getDouble("subtotal"),
        total = json.getDouble("total"),
        freight = json.getDouble("freight"),
        tax = json.getDouble("tax"),
        discounts = json.getDouble("discounts"),
        currency = json.stringOrNull("currency"),
        coupons = json.optJSONArray("coupons")?.let { arr -> (0 until arr.length()).map { arr.getString(it) } },
        items = json.optJSONArray("items")?.objects()?.map { cartItem(it) },
        deliveryAddress = json.optJSONObject("deliveryAddress")?.let { address(it) },
        paymentMethods = json.optJSONArray("paymentMethods")?.objects()?.map {
            PaymentMethod(type = it.getString("type"), amount = it.getDouble("amount"))
        },
        deliveryMethods = json.optJSONArray("deliveryMethods")?.objects()?.map {
            DeliveryMethod(type = it.getString("type"), amount = it.getDouble("amount"))
        },
    )

    /**
     * Structural comparison — key order irrelevant, numbers compared by double
     * value (`0` == `0.0`). Returns a description of the first difference, or
     * null when equivalent.
     */
    fun diff(expected: Any?, actual: Any?, path: String): String? {
        val exp = if (expected == JSONObject.NULL) null else expected
        val act = if (actual == JSONObject.NULL) null else actual
        return when {
            exp == null && act == null -> null
            exp == null || act == null -> "$path: expected $exp but was $act"
            exp is JSONObject && act is JSONObject -> {
                val expKeys = exp.keyNames()
                val actKeys = act.keyNames()
                if (expKeys != actKeys) {
                    val missing = expKeys - actKeys
                    val extra = actKeys - expKeys
                    "$path: key mismatch (missing=$missing, unexpected=$extra)"
                } else {
                    expKeys.firstNotNullOfOrNull { key: String -> diff(exp.get(key), act.get(key), "$path.$key") }
                }
            }
            exp is JSONArray && act is JSONArray -> {
                if (exp.length() != act.length()) {
                    "$path: array length ${exp.length()} != ${act.length()}"
                } else {
                    (0 until exp.length()).firstNotNullOfOrNull { i -> diff(exp.get(i), act.get(i), "$path[$i]") }
                }
            }
            exp is Boolean || act is Boolean ->
                if (exp == act) null else "$path: expected $exp but was $act"
            exp is Number && act is Number ->
                if (exp.toDouble() == act.toDouble()) null else "$path: expected $exp but was $act"
            else ->
                if (exp == act) null else "$path: expected ${exp::class.simpleName}($exp) but was ${act::class.simpleName}($act)"
        }
    }

    // --- JSON extraction helpers (org.json opt* return sentinel defaults, we want nulls) ---

    private fun JSONObject.stringOrNull(key: String): String? =
        if (has(key) && !isNull(key)) getString(key) else null

    private fun JSONObject.doubleOrNull(key: String): Double? =
        if (has(key) && !isNull(key)) getDouble(key) else null

    private fun JSONObject.intOrNull(key: String): Int? =
        if (has(key) && !isNull(key)) getInt(key) else null

    private fun JSONObject.boolOrNull(key: String): Boolean? =
        if (has(key) && !isNull(key)) getBoolean(key) else null

    private fun JSONObject.mapOrNull(key: String): Map<String, Any?>? =
        optJSONObject(key)?.toPlainMap()

    private fun JSONArray.objects(): List<JSONObject> =
        (0 until length()).map { getJSONObject(it) }

    /** Android's org.json has no `keySet()`; `keys()` exists on both implementations. */
    private fun JSONObject.keyNames(): Set<String> {
        val result = linkedSetOf<String>()
        val iterator = keys()
        while (iterator.hasNext()) result += iterator.next() as String
        return result
    }

    private fun JSONObject.toPlainMap(): Map<String, Any?> =
        keyNames().associateWith { key -> get(key).toPlainValue() }

    private fun Any?.toPlainValue(): Any? = when (this) {
        null, JSONObject.NULL -> null
        is JSONObject -> toPlainMap()
        is JSONArray -> (0 until length()).map { get(it).toPlainValue() }
        else -> this
    }
}
