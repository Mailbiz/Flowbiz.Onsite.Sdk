import Foundation

/// Payload value types for the typed event catalog (SPEC §5).
///
/// Properties are camelCase; serialization emits snake_case wire keys (see
/// `EventSerializer`). Optional (`nil`) fields are omitted from the wire
/// entirely — `"key": null` never appears. All types are `Sendable` value
/// types (SPEC §3); free-form maps use ``JSONValue``.

/// User payload for `accountLogin` / `accountSync`.
public struct User: Sendable, Equatable {
    public let userId: String
    public let email: String
    public let phone: String?
    public let name: String?
    public let plan: String?
    public let createdAt: String?

    public init(
        userId: String,
        email: String,
        phone: String? = nil,
        name: String? = nil,
        plan: String? = nil,
        createdAt: String? = nil
    ) {
        self.userId = userId
        self.email = email
        self.phone = phone
        self.name = name
        self.plan = plan
        self.createdAt = createdAt
    }
}

/// A purchasable variant of a ``Product``.
public struct ProductVariant: Sendable, Equatable {
    public let sku: String
    public let price: Double
    public let name: String?
    public let url: String?
    public let imageUrl: String?
    public let priceFrom: Double?
    public let stock: Int?
    public let available: Bool?
    public let properties: [String: JSONValue]?
    public let recoveryProperties: [String: JSONValue]?

    public init(
        sku: String,
        price: Double,
        name: String? = nil,
        url: String? = nil,
        imageUrl: String? = nil,
        priceFrom: Double? = nil,
        stock: Int? = nil,
        available: Bool? = nil,
        properties: [String: JSONValue]? = nil,
        recoveryProperties: [String: JSONValue]? = nil
    ) {
        self.sku = sku
        self.price = price
        self.name = name
        self.url = url
        self.imageUrl = imageUrl
        self.priceFrom = priceFrom
        self.stock = stock
        self.available = available
        self.properties = properties
        self.recoveryProperties = recoveryProperties
    }
}

/// Product payload for `productView`.
public struct Product: Sendable, Equatable {
    public let productId: String
    public let url: String?
    public let category: String?
    public let brand: String?
    public let variants: [ProductVariant]

    public init(
        productId: String,
        url: String? = nil,
        category: String? = nil,
        brand: String? = nil,
        variants: [ProductVariant]
    ) {
        self.productId = productId
        self.url = url
        self.category = category
        self.brand = brand
        self.variants = variants
    }
}

/// A line item inside a ``Cart``, `addToCart` or an ``Order``.
public struct CartItem: Sendable, Equatable {
    public let productId: String
    public let sku: String
    public let quantity: Int
    public let price: Double
    public let name: String?
    public let priceFrom: Double?
    public let category: String?
    public let brand: String?
    public let url: String?
    public let imageUrl: String?
    public let properties: [String: JSONValue]?
    public let recoveryProperties: [String: JSONValue]?

    public init(
        productId: String,
        sku: String,
        quantity: Int,
        price: Double,
        name: String? = nil,
        priceFrom: Double? = nil,
        category: String? = nil,
        brand: String? = nil,
        url: String? = nil,
        imageUrl: String? = nil,
        properties: [String: JSONValue]? = nil,
        recoveryProperties: [String: JSONValue]? = nil
    ) {
        self.productId = productId
        self.sku = sku
        self.quantity = quantity
        self.price = price
        self.name = name
        self.priceFrom = priceFrom
        self.category = category
        self.brand = brand
        self.url = url
        self.imageUrl = imageUrl
        self.properties = properties
        self.recoveryProperties = recoveryProperties
    }
}

/// Delivery address for ``Cart`` / ``Order``.
public struct Address: Sendable, Equatable {
    public let postalCode: String?
    public let addressLine1: String?
    public let addressNumber: String?
    public let addressLine2: String?
    public let city: String?
    public let state: String?
    public let country: String?
    public let neighborhood: String?

    public init(
        postalCode: String? = nil,
        addressLine1: String? = nil,
        addressNumber: String? = nil,
        addressLine2: String? = nil,
        city: String? = nil,
        state: String? = nil,
        country: String? = nil,
        neighborhood: String? = nil
    ) {
        self.postalCode = postalCode
        self.addressLine1 = addressLine1
        self.addressNumber = addressNumber
        self.addressLine2 = addressLine2
        self.city = city
        self.state = state
        self.country = country
        self.neighborhood = neighborhood
    }
}

/// Cart payload for `cartSync`. An empty-items cart is valid and always sent (SPEC §7).
public struct Cart: Sendable, Equatable {
    public let cartId: String
    public let subtotal: Double
    public let total: Double
    public let freight: Double
    public let tax: Double
    public let discounts: Double
    public let currency: String?
    public let coupons: [String]?
    public let items: [CartItem]?
    public let deliveryAddress: Address?

    public init(
        cartId: String,
        subtotal: Double,
        total: Double,
        freight: Double,
        tax: Double,
        discounts: Double,
        currency: String? = nil,
        coupons: [String]? = nil,
        items: [CartItem]? = nil,
        deliveryAddress: Address? = nil
    ) {
        self.cartId = cartId
        self.subtotal = subtotal
        self.total = total
        self.freight = freight
        self.tax = tax
        self.discounts = discounts
        self.currency = currency
        self.coupons = coupons
        self.items = items
        self.deliveryAddress = deliveryAddress
    }
}

/// Checkout progress payload for `checkoutStep`.
public struct Checkout: Sendable, Equatable {
    public let cartId: String
    public let step: Int
    public let totalSteps: Int
    public let stepName: String

    public init(cartId: String, step: Int, totalSteps: Int, stepName: String) {
        self.cartId = cartId
        self.step = step
        self.totalSteps = totalSteps
        self.stepName = stepName
    }
}

/// A payment method entry on an ``Order``.
public struct PaymentMethod: Sendable, Equatable {
    public let type: String
    public let amount: Double

    public init(type: String, amount: Double) {
        self.type = type
        self.amount = amount
    }
}

/// A delivery method entry on an ``Order``.
public struct DeliveryMethod: Sendable, Equatable {
    public let type: String
    public let amount: Double

    public init(type: String, amount: Double) {
        self.type = type
        self.amount = amount
    }
}

/// Order payload for `orderComplete`.
public struct Order: Sendable, Equatable {
    public let cartId: String
    public let orderId: String?
    public let subtotal: Double
    public let total: Double
    public let freight: Double
    public let tax: Double
    public let discounts: Double
    public let currency: String?
    public let coupons: [String]?
    public let items: [CartItem]?
    public let deliveryAddress: Address?
    public let paymentMethods: [PaymentMethod]?
    public let deliveryMethods: [DeliveryMethod]?

    public init(
        cartId: String,
        orderId: String? = nil,
        subtotal: Double,
        total: Double,
        freight: Double,
        tax: Double,
        discounts: Double,
        currency: String? = nil,
        coupons: [String]? = nil,
        items: [CartItem]? = nil,
        deliveryAddress: Address? = nil,
        paymentMethods: [PaymentMethod]? = nil,
        deliveryMethods: [DeliveryMethod]? = nil
    ) {
        self.cartId = cartId
        self.orderId = orderId
        self.subtotal = subtotal
        self.total = total
        self.freight = freight
        self.tax = tax
        self.discounts = discounts
        self.currency = currency
        self.coupons = coupons
        self.items = items
        self.deliveryAddress = deliveryAddress
        self.paymentMethods = paymentMethods
        self.deliveryMethods = deliveryMethods
    }
}
