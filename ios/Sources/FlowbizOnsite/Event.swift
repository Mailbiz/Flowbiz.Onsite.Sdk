import Foundation

/// Sent as given, except the account `User` (see it); nil fields are omitted.
public enum Event: Sendable, Equatable {

    /// `path` is resolved against `FlowbizConfig.baseUri`; it becomes `context.url` from this event on.
    case pageView(path: String? = nil, title: String? = nil)

    case accountLogin(user: User)
    case accountSync(user: User)

    case productView(product: Product)
    case cartSync(cart: Cart)
    case addToCart(products: [CartItem])
    case cartItemUpdate(cartId: String, productId: String, sku: String, quantity: Int)
    case cartSetPostalCode(cartId: String, postalCode: String)
    case cartSetCoupon(cartId: String, coupon: String)
    case checkoutStep(checkout: Checkout)
    case orderComplete(order: Order)

    /// Provide at least one of `orderId` and `cartId`.
    case orderCancel(orderId: String?, cartId: String?)
}
