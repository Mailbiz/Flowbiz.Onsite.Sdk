import Foundation

/// An event for `Flowbiz.track`. Payloads are sent as given, with nil fields
/// omitted: types replace the web tag's runtime validation, and nothing is
/// enriched.
public enum Event: Sendable, Equatable {

    /// `page.view` — `path` is resolved against `FlowbizConfig.baseUri`
    /// into `page.url` and the remembered `context.url`;
    /// `title` ships as `page.title`. Both optional.
    case pageView(path: String? = nil, title: String? = nil)

    /// `account.login`; this and later events carry `user.userId` as
    /// `identity.user_id` until logout.
    case accountLogin(user: User)

    /// `account.sync`; this and later events carry `user.userId` as
    /// `identity.user_id` until logout.
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
