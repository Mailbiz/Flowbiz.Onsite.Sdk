import Foundation
import FlowbizOnsite

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

struct CartLine: Identifiable {
    let product: DemoProduct
    var quantity: Int

    var id: String { product.sku }
}

final class DemoStore: ObservableObject {

    static let cartId = "demo-cart-001"

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
            url: "/camisa-linho-azul-marinho",
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
            url: "/meia-cano-alto-branca",
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
            url: "/camiseta-estampada-acai",
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
            url: "/tenis-urbano-couro-branco",
            imageUrl: "https://cdn.belamodastore.com.br/produtos/p200-m.jpg",
            properties: ["cor": "Branco", "tamanho": "M"]
        ),
    ]

    static let fakeUser = User(
        userId: "u-9f2c",
        email: "maria.souza@exemplo.com.br",
        phone: "+55 11 91234-5678",
        name: "Maria Souza",
        plan: "vip",
        createdAt: "2024-03-10T12:00:00Z"
    )

    static let fakePushToken = "fake-apns-token-0123456789abcdef"

    static let recoveryHash =
        "eyJ0IjoiNzc3NzciLCJ1IjoidXNlci0xMjMiLCJjIjoiY2FydC1hYmMtMDAxIiwiaXRzIjpbWyIyIiwiUDEwMCIsIlNLVS0xMDAtUCJdLFsiMSIsIlAyMDAiLCJTS1UtMjAwLU0iXV19"

    // %7C, not a raw "|": URL(string:) returns nil for it before iOS 17.
    static let recoveryLink =
        "flowbizdemo://recover?_mb_cr_=\(recoveryHash)&utm_journey=16&utm_journey_channel=email" +
        "&utm_source=flowbiz&utm_medium=email&utm_campaign=jornadas%7Ccart%7Ccarrinho-abandonado&utm_journey_type=1"

    static let simulatedPushMarker =
        #"{"v":1,"type":"cart_recovery","title":"Sua sacola te espera!","body":"Finalize sua compra...","deep_link":"https://store.com/carrinho?utm_source=flowbiz&_mb_cr_=eyJ0IjoiNzc3NzciLCJ1IjoidXNlci0xMjMiLCJjIjoiY2FydC1hYmMtMDAxIiwiaXRzIjpbWyIyIiwiUDEwMCIsIlNLVS0xMDAtUCIsIntcImNvclwiOlwiQXp1bFwiLFwidGFtYW5ob1wiOlwiUFwifSJdLFsiMSIsIlAyMDAiLCJTS1UtMjAwLU0iXV19","data":{"campaign_id":"cr-42"}}"#

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

    func restore(_ payload: RecoveryPayload) {
        clear()
        for line in payload.products {
            let product = catalog.first { $0.sku == line.sku }
                ?? catalog.first { $0.productId == line.productId }
            guard let product else { continue }
            add(product, quantity: line.quantity)
        }
    }

    var subtotal: Double { round2(lines.reduce(0) { $0 + $1.product.price * Double($1.quantity) }) }

    var discounts: Double { coupon == nil ? 0 : round2(subtotal * 0.10) }

    var freight: Double { lines.isEmpty ? 0 : 22.9 }

    var total: Double { round2(subtotal - discounts + freight) }

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
