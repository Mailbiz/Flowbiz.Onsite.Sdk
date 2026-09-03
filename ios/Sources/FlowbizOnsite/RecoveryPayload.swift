import Foundation

/// Result of `Flowbiz.handleLink` (SPEC §11): the decoded cart-recovery
/// payload carried by an `_mb_cr_` deep link. The app restores the cart
/// however it wants — the SDK only returns data (it does not adopt
/// `userId` as its identity; SPEC §11).
public struct RecoveryPayload: Sendable, Equatable {
    public let cartId: String
    public let userId: String
    public let products: [RecoveryProduct]
}

/// One recovered cart line (SPEC §11), mapped from a hash `its` entry
/// `[quantity, product_id, sku, recovery_properties?]` with the web
/// `buildCartRecoveryPayload` semantics (onsite-universal-vendor):
///
/// - `quantity`: JS `parseInt(it[0]) || 1` — unparseable *and* `0` fall
///   back to 1 (`0` is falsy in JS);
/// - `productId` / `sku`: missing/falsy → `""`;
/// - `recoveryProperties`: the 4th element parsed as a JSON-object string;
///   absent or unparseable → nil (the web emits `{}` — same "no
///   properties" meaning, mapped to the platform-idiomatic nil).
public struct RecoveryProduct: Sendable, Equatable {
    public let productId: String
    public let sku: String
    public let quantity: Int
    public let recoveryProperties: [String: JSONValue]?
}
