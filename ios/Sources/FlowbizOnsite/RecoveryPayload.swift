import Foundation

/// The cart carried by an `_mb_cr_` recovery link, from `Flowbiz.handleLink`.
/// Restoring the cart is up to the app; the SDK does not adopt `userId` as
/// its identity.
public struct RecoveryPayload: Sendable, Equatable {
    public let cartId: String
    public let userId: String
    public let products: [RecoveryProduct]
}

/// One recovered cart line, decoded like the web `buildCartRecoveryPayload`:
/// `quantity` is 1 when unparseable or `0`, missing ids are `""`, and
/// `recoveryProperties` is nil when absent or unparseable (the web's `{}`).
public struct RecoveryProduct: Sendable, Equatable {
    public let productId: String
    public let sku: String
    public let quantity: Int
    public let recoveryProperties: [String: JSONValue]?
}
