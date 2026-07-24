import Foundation

/// Typed event catalog — the single typed entry point of SPEC §5.
///
/// Compile-time typing replaces the web Yup layer: there is no runtime schema
/// validation and no field enrichment. Integrators build complete typed
/// payloads; the SDK serializes them verbatim (snake_case wire keys, optional
/// fields omitted when nil). All cases carry `Sendable` value types (SPEC §3).
public enum Event: Sendable, Equatable {

    /// `page.view` — `screenName` also drives the synthetic `app://<screenName>` context URL.
    case pageView(screenName: String?)

    /// `account.login`.
    case accountLogin(user: User)

    /// `account.sync`.
    case accountSync(user: User)

    /// `product.view`.
    case productView(product: Product)

    /// `cart.sync`.
    case cartSync(cart: Cart)

    /// `cart.add`.
    case addToCart(products: [CartItem])

    /// `cart.item.update`.
    case cartItemUpdate(cartId: String, productId: String, sku: String, quantity: Int)

    /// `cart.setpostalcode`.
    case cartSetPostalCode(cartId: String, postalCode: String)

    /// `cart.setcoupon`.
    case cartSetCoupon(cartId: String, coupon: String)

    /// `checkout.step`.
    case checkoutStep(checkout: Checkout)

    /// `order.complete`.
    case orderComplete(order: Order)

    /// `order.cancel` — at least one of `orderId` / `cartId` should be provided.
    case orderCancel(orderId: String?, cartId: String?)
}
