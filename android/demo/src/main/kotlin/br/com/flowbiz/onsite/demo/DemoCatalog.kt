package br.com.flowbiz.onsite.demo

import br.com.flowbiz.onsite.Address
import br.com.flowbiz.onsite.Cart
import br.com.flowbiz.onsite.CartItem
import br.com.flowbiz.onsite.DeliveryMethod
import br.com.flowbiz.onsite.Order
import br.com.flowbiz.onsite.PaymentMethod
import br.com.flowbiz.onsite.Product
import br.com.flowbiz.onsite.ProductVariant
import br.com.flowbiz.onsite.RecoveryPayload
import br.com.flowbiz.onsite.User

data class DemoProduct(
    val productId: String,
    val sku: String,
    val name: String,
    val brand: String,
    val category: String,
    val price: Double,
    val priceFrom: Double,
    val url: String,
    val imageUrl: String,
    val properties: Map<String, Any?>,
)

object DemoCatalog {

    val products: List<DemoProduct> = listOf(
        DemoProduct(
            productId = "CAM-778",
            sku = "CAM-778-P-AZ",
            name = "Camisa de Linho Azul Marinho - P",
            brand = "Reserva",
            category = "Roupas > Camisas",
            price = 189.9,
            priceFrom = 249.9,
            url = "/camisa-linho-azul-marinho",
            imageUrl = "https://cdn.belamodastore.com.br/produtos/cam-778-az-p.jpg",
            properties = mapOf("cor" to "Azul Marinho", "tamanho" to "P"),
        ),
        DemoProduct(
            productId = "MEI-330",
            sku = "MEI-330-U",
            name = "Meia Cano Alto Branca - Único",
            brand = "Lupo",
            category = "Roupas > Meias",
            price = 29.9,
            priceFrom = 39.9,
            url = "/meia-cano-alto-branca",
            imageUrl = "https://cdn.belamodastore.com.br/produtos/mei-330-u.jpg",
            properties = mapOf("cor" to "Branca", "tamanho" to "Único"),
        ),
        DemoProduct(
            productId = "P100",
            sku = "SKU-100-P",
            name = "Camiseta Estampada Açaí - P",
            brand = "Osklen",
            category = "Roupas > Camisetas",
            price = 119.9,
            priceFrom = 149.9,
            url = "/camiseta-estampada-acai",
            imageUrl = "https://cdn.belamodastore.com.br/produtos/p100-p.jpg",
            properties = mapOf("cor" to "Azul", "tamanho" to "P"),
        ),
        DemoProduct(
            productId = "P200",
            sku = "SKU-200-M",
            name = "Tênis Urbano Couro Branco - M",
            brand = "Olympikus",
            category = "Calçados > Tênis",
            price = 349.9,
            priceFrom = 429.9,
            url = "/tenis-urbano-couro-branco",
            imageUrl = "https://cdn.belamodastore.com.br/produtos/p200-m.jpg",
            properties = mapOf("cor" to "Branco", "tamanho" to "M"),
        ),
    )

    val fakeUser = User(
        userId = "u-9f2c",
        email = "maria.souza@exemplo.com.br",
        phone = "+55 11 91234-5678",
        name = "Maria Souza",
        plan = "vip",
        createdAt = "2024-03-10T12:00:00Z",
    )

    fun bySku(sku: String): DemoProduct? = products.firstOrNull { it.sku == sku }

    fun byProductId(productId: String): DemoProduct? =
        products.firstOrNull { it.productId == productId }

    fun toSdkProduct(product: DemoProduct): Product = Product(
        productId = product.productId,
        url = product.url,
        category = product.category,
        brand = product.brand,
        variants = listOf(
            ProductVariant(
                sku = product.sku,
                price = product.price,
                name = product.name,
                url = product.url,
                imageUrl = product.imageUrl,
                priceFrom = product.priceFrom,
                stock = 12,
                available = true,
                properties = product.properties,
                recoveryProperties = mapOf("seller_id" to "1"),
            )
        ),
    )
}

object DemoCart {

    const val CART_ID = "demo-cart-001"

    private val quantities = LinkedHashMap<String, Int>()
    var coupon: String? = null
    var postalCode: String? = null

    val lines: List<Pair<DemoProduct, Int>>
        get() = quantities.mapNotNull { (sku, qty) -> DemoCatalog.bySku(sku)?.let { it to qty } }

    val itemCount: Int
        get() = quantities.values.sum()

    fun add(product: DemoProduct, quantity: Int = 1) {
        quantities[product.sku] = (quantities[product.sku] ?: 0) + quantity
    }

    fun setQuantity(sku: String, quantity: Int) {
        if (quantity <= 0) quantities.remove(sku) else quantities[sku] = quantity
    }

    fun clear() {
        quantities.clear()
        coupon = null
        postalCode = null
    }

    fun subtotal(): Double = round2(lines.sumOf { (product, qty) -> product.price * qty })

    fun discounts(): Double = if (coupon == null) 0.0 else round2(subtotal() * 0.10)

    fun freight(): Double = if (quantities.isEmpty()) 0.0 else 22.9

    fun total(): Double = round2(subtotal() - discounts() + freight())

    fun toCartItem(product: DemoProduct, quantity: Int): CartItem = CartItem(
        productId = product.productId,
        sku = product.sku,
        quantity = quantity,
        price = product.price,
        name = product.name,
        priceFrom = product.priceFrom,
        category = product.category,
        brand = product.brand,
        url = product.url,
        imageUrl = product.imageUrl,
        properties = product.properties,
        recoveryProperties = mapOf("seller_id" to "1"),
    )

    fun toCart(): Cart = Cart(
        cartId = CART_ID,
        subtotal = subtotal(),
        total = total(),
        freight = freight(),
        tax = 0.0,
        discounts = discounts(),
        currency = "BRL",
        coupons = coupon?.let(::listOf),
        items = lines.map { (product, qty) -> toCartItem(product, qty) },
        deliveryAddress = deliveryAddress(),
    )

    fun toOrder(orderId: String): Order = Order(
        cartId = CART_ID,
        orderId = orderId,
        subtotal = subtotal(),
        total = total(),
        freight = freight(),
        tax = 0.0,
        discounts = discounts(),
        currency = "BRL",
        coupons = coupon?.let(::listOf),
        items = lines.map { (product, qty) -> toCartItem(product, qty) },
        deliveryAddress = deliveryAddress(),
        paymentMethods = listOf(PaymentMethod(type = "credit_card", amount = total())),
        deliveryMethods = listOf(DeliveryMethod(type = "sedex", amount = freight())),
    )

    fun restore(payload: RecoveryPayload) {
        quantities.clear()
        coupon = null
        postalCode = null
        payload.products.forEach { line ->
            val product = DemoCatalog.bySku(line.sku)
                ?: DemoCatalog.byProductId(line.productId)
                ?: return@forEach
            quantities[product.sku] = line.quantity
        }
    }

    private fun deliveryAddress(): Address? = postalCode?.let {
        Address(postalCode = it, city = "São Paulo", state = "SP", country = "BR")
    }

    private fun round2(value: Double): Double = Math.round(value * 100.0) / 100.0
}
