import Foundation
import FlowbizOnsite

/// One fake-store product. Data mirrors the realistic Brazilian ecommerce
/// catalog used by `shared/fixtures/` (Bela Moda Store); `P100`/`P200` match
/// the product ids inside the shared recovery-link vectors so a simulated
/// recovery link restores real catalog items. Mirrors the Android demo 1:1.
struct DemoProduct: Identifiable {
    let productId: String
    let sku: String
    let name: String
    let brand: String
    let category: String
    let price: Double
    let priceFrom: Double
    let url: String
    let imageUrl: String
    let properties: [String: JSONValue]

    var id: String { sku }
}

/// A cart line in the demo store's in-memory state.
struct CartLine: Identifiable {
    let product: DemoProduct
    var quantity: Int

    var id: String { product.sku }
}

/// In-memory demo store state: catalog, cart, and the pending deep-link
/// recovery result. The SDK payloads the demo tracks are built from here.
final class DemoStore: ObservableObject {

    static let cartId = "demo-cart-001"

    /// Presented as a sheet showing the parsed `RecoveryPayload` (SPEC §11).
    struct RecoveryResult: Identifiable {
        let id = UUID()
        let source: String
        let payload: RecoveryPayload?
    }

    @Published var lines: [CartLine] = []
    @Published var coupon: String?
    @Published var postalCode: String?
    @Published var loggedIn = false
    @Published var recovery: RecoveryResult?

    let catalog: [DemoProduct] = [
        DemoProduct(
            productId: "CAM-778",
            sku: "CAM-778-P-AZ",
            name: "Camisa de Linho Azul Marinho - P",
            brand: "Reserva",
            category: "Roupas > Camisas",
            price: 189.9,
            priceFrom: 249.9,
            url: "https://www.belamodastore.com.br/camisa-linho-azul-marinho",
            imageUrl: "https://cdn.belamodastore.com.br/produtos/cam-778-az-p.jpg",
            properties: ["cor": "Azul Marinho", "tamanho": "P"]
        ),
        DemoProduct(
            productId: "MEI-330",
            sku: "MEI-330-U",
            name: "Meia Cano Alto Branca - Único",
            brand: "Lupo",
            category: "Roupas > Meias",
            price: 29.9,
            priceFrom: 39.9,
            url: "https://www.belamodastore.com.br/meia-cano-alto-branca",
            imageUrl: "https://cdn.belamodastore.com.br/produtos/mei-330-u.jpg",
            properties: ["cor": "Branca", "tamanho": "Único"]
        ),
        DemoProduct(
            productId: "P100",
            sku: "SKU-100-P",
            name: "Camiseta Estampada Açaí - P",
            brand: "Osklen",
            category: "Roupas > Camisetas",
            price: 119.9,
            priceFrom: 149.9,
            url: "https://www.belamodastore.com.br/camiseta-estampada-acai",
            imageUrl: "https://cdn.belamodastore.com.br/produtos/p100-p.jpg",
            properties: ["cor": "Azul", "tamanho": "P"]
        ),
        DemoProduct(
            productId: "P200",
            sku: "SKU-200-M",
            name: "Tênis Urbano Couro Branco - M",
            brand: "Olympikus",
            category: "Calçados > Tênis",
            price: 349.9,
            priceFrom: 429.9,
            url: "https://www.belamodastore.com.br/tenis-urbano-couro-branco",
            imageUrl: "https://cdn.belamodastore.com.br/produtos/p200-m.jpg",
            properties: ["cor": "Branco", "tamanho": "M"]
        ),
    ]

    /// Fake logged-in user for `account.login` / `account.sync` (SPEC §5).
    static let fakeUser = User(
        userId: "u-9f2c",
        email: "maria.souza@exemplo.com.br",
        phone: "+55 11 91234-5678",
        name: "Maria Souza",
        plan: "vip",
        createdAt: "2024-03-10T12:00:00Z"
    )

    static let fakePushToken = "fake-apns-token-0123456789abcdef"

    /// `recovery_hash_basic` from shared/lzstring-vectors/vectors.json —
    /// decodes to cart-abc-001 / user-123 / P100 + P200.
    static let recoveryHash =
        "N4IgLiBcIOx3IA0ICuVUGcCmAnAtAIwBMAzEiAMboUCGOYeNARhXgAxsHkCWYGUAbQEgi5AAoEO5AMoBpAKqEOeMSAC6iYV2RiiU5HMV62eALLq1AXyA"

    /// SPEC §10.2 marker value from shared/push-samples/samples.json
    /// ("cart_recovery_with_real_mb_recovery_deep_link").
    static let simulatedPushMarker =
        #"{"v":1,"type":"cart_recovery","title":"Sua sacola te espera!","body":"Finalize sua compra...","deep_link":"https://store.com/recover?utm_source=flowbiz&mb_recovery=N4IgLiBcIOx3IA0ICuVUGcCmAnAtAIwBMAzEiAMboUCGOYeNARhXgAxsHkCWYGUAbQEgi5AAoEO5AMoBpAKqEOeMeWAAdSgHscmyJoCCALxQAbTYk1gaAWxoA7ABZa9msZoC+IALqJhXZDEiKWQ5RWC2PABZH28PIA","data":{"campaign_id":"cr-42"}}"#

    // MARK: - Cart mutations

    var itemCount: Int { lines.reduce(0) { $0 + $1.quantity } }

    func add(_ product: DemoProduct, quantity: Int = 1) {
        if let index = lines.firstIndex(where: { $0.product.sku == product.sku }) {
            lines[index].quantity += quantity
        } else {
            lines.append(CartLine(product: product, quantity: quantity))
        }
    }

    func setQuantity(sku: String, quantity: Int) {
        guard let index = lines.firstIndex(where: { $0.product.sku == sku }) else { return }
        if quantity <= 0 {
            lines.remove(at: index)
        } else {
            lines[index].quantity = quantity
        }
    }

    func clear() {
        lines = []
        coupon = nil
        postalCode = nil
    }

    /// Restores recovered lines (SPEC §11) into the demo cart. Recovery lines
    /// are matched to the catalog by sku, then product_id; unknown lines are
    /// skipped (a real store would fetch them from its own backend).
    func restore(_ payload: RecoveryPayload) {
        clear()
        for line in payload.products {
            let product = catalog.first { $0.sku == line.sku }
                ?? catalog.first { $0.productId == line.productId }
            guard let product else { continue }
            add(product, quantity: line.quantity)
        }
    }

    // MARK: - Totals (fake but arithmetically consistent)

    var subtotal: Double { round2(lines.reduce(0) { $0 + $1.product.price * Double($1.quantity) }) }

    /// Flat 10% off with any coupon applied.
    var discounts: Double { coupon == nil ? 0 : round2(subtotal * 0.10) }

    var freight: Double { lines.isEmpty ? 0 : 22.9 }

    var total: Double { round2(subtotal - discounts + freight) }

    // MARK: - SDK payload builders

    /// SDK `Product` payload for `product.view` (SPEC §5), one variant per demo product.
    func sdkProduct(_ product: DemoProduct) -> Product {
        Product(
            productId: product.productId,
            url: product.url,
            category: product.category,
            brand: product.brand,
            variants: [
                ProductVariant(
                    sku: product.sku,
                    price: product.price,
                    name: product.name,
                    url: product.url,
                    imageUrl: product.imageUrl,
                    priceFrom: product.priceFrom,
                    stock: 12,
                    available: true,
                    properties: product.properties,
                    recoveryProperties: ["seller_id": "1"]
                )
            ]
        )
    }

    func cartItem(_ product: DemoProduct, quantity: Int) -> CartItem {
        CartItem(
            productId: product.productId,
            sku: product.sku,
            quantity: quantity,
            price: product.price,
            name: product.name,
            priceFrom: product.priceFrom,
            category: product.category,
            brand: product.brand,
            url: product.url,
            imageUrl: product.imageUrl,
            properties: product.properties,
            recoveryProperties: ["seller_id": "1"]
        )
    }

    /// SDK `Cart` payload for `cart.sync` (SPEC §5); an empty cart is valid
    /// and always sent (SPEC §7).
    func cart() -> Cart {
        Cart(
            cartId: DemoStore.cartId,
            subtotal: subtotal,
            total: total,
            freight: freight,
            tax: 0,
            discounts: discounts,
            currency: "BRL",
            coupons: coupon.map { [$0] },
            items: lines.map { cartItem($0.product, quantity: $0.quantity) },
            deliveryAddress: deliveryAddress()
        )
    }

    /// SDK `Order` payload for `order.complete` (SPEC §5).
    func order(orderId: String) -> Order {
        Order(
            cartId: DemoStore.cartId,
            orderId: orderId,
            subtotal: subtotal,
            total: total,
            freight: freight,
            tax: 0,
            discounts: discounts,
            currency: "BRL",
            coupons: coupon.map { [$0] },
            items: lines.map { cartItem($0.product, quantity: $0.quantity) },
            deliveryAddress: deliveryAddress(),
            paymentMethods: [PaymentMethod(type: "credit_card", amount: total)],
            deliveryMethods: [DeliveryMethod(type: "sedex", amount: freight)]
        )
    }

    private func deliveryAddress() -> Address? {
        postalCode.map { Address(postalCode: $0, city: "São Paulo", state: "SP", country: "BR") }
    }

    private func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
