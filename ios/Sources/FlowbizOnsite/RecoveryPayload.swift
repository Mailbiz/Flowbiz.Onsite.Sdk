import Foundation

/// Restoring the cart is up to the app; the SDK does not adopt `userId` as its identity.
public struct RecoveryPayload: Sendable, Equatable {
    public let cartId: String
    public let userId: String
    public let products: [RecoveryProduct]
}

/// Web fallbacks apply: a missing id is `""`, a 0 or unparseable `quantity` is 1.
public struct RecoveryProduct: Sendable, Equatable {
    public let productId: String
    public let sku: String
    public let quantity: Int
    public let recoveryProperties: [String: JSONValue]?
}
