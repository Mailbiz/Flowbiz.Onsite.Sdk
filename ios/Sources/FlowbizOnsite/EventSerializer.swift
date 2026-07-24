import Foundation

/// Event → wire serialization (SPEC §5).
///
/// Maps a typed ``Event`` to its wire event name and its `data` payload JSON
/// string: snake_case keys, optional (`nil`) fields omitted entirely.
/// Free-form `properties` / `recoveryProperties` maps are passed through with
/// their keys untouched; `.null` values inside objects are dropped (inside
/// arrays a `.null` element is kept as JSON `null` to preserve positions).
///
/// Must stay behaviorally identical to the Kotlin `EventSerializer` — both
/// are pinned by the shared fixtures in `shared/fixtures/`. The produced wire
/// string is rendered by ``CanonicalJSON`` (sorted keys, `JSON.stringify`
/// number rendering and escaping) and is byte-identical across platforms.
///
/// Garbage-input contract (aligned with Kotlin): serialization **throws** on
/// non-finite numbers (NaN/±Infinity) — org.json throws `JSONException` for
/// the same input. SPEC §3's never-throw boundary is applied at the public
/// API in Slice 4; internally serialization is strict.
enum EventSerializer {

    /// Wire event name (SPEC §5 table).
    static func wireName(_ event: Event) -> String {
        switch event {
        case .pageView: return "page.view"
        case .accountLogin: return "account.login"
        case .accountSync: return "account.sync"
        case .productView: return "product.view"
        case .cartSync: return "cart.sync"
        case .addToCart: return "cart.add"
        case .cartItemUpdate: return "cart.item.update"
        case .cartSetPostalCode: return "cart.setpostalcode"
        case .cartSetCoupon: return "cart.setcoupon"
        case .checkoutStep: return "checkout.step"
        case .orderComplete: return "order.complete"
        case .orderCancel: return "order.cancel"
        }
    }

    /// The envelope `data` field value: the payload as a canonical JSON
    /// string (see ``CanonicalJSON``). Throws only for non-finite numbers.
    static func dataJSONString(_ event: Event) throws -> String {
        try CanonicalJSON.render(dataObject(event))
    }

    /// The payload as a JSON-compatible dictionary (snake_case keys, nils omitted).
    static func dataObject(_ event: Event) -> [String: Any] {
        switch event {
        case .pageView(let screenName):
            var page = [String: Any]()
            if let screenName {
                page["title"] = screenName
                page["url"] = "app://\(screenName)"
            }
            return ["page": page]

        case .accountLogin(let user), .accountSync(let user):
            return ["user": userObject(user)]

        case .productView(let product):
            return ["product": productObject(product)]

        case .cartSync(let cart):
            return ["cart": cartObject(cart)]

        case .addToCart(let products):
            return ["products": products.map(cartItemObject)]

        case .cartItemUpdate(let cartId, let productId, let sku, let quantity):
            return [
                "cart_id": cartId,
                "product_id": productId,
                "sku": sku,
                "quantity": quantity,
            ]

        case .cartSetPostalCode(let cartId, let postalCode):
            return ["cart_id": cartId, "postal_code": postalCode]

        case .cartSetCoupon(let cartId, let coupon):
            return ["cart_id": cartId, "coupon": coupon]

        case .checkoutStep(let checkout):
            return [
                "checkout": [
                    "cart_id": checkout.cartId,
                    "step": checkout.step,
                    "total_steps": checkout.totalSteps,
                    "step_name": checkout.stepName,
                ] as [String: Any]
            ]

        case .orderComplete(let order):
            return ["order": orderObject(order)]

        case .orderCancel(let orderId, let cartId):
            var payload = [String: Any]()
            setIfPresent(&payload, "order_id", orderId)
            setIfPresent(&payload, "cart_id", cartId)
            return payload
        }
    }

    private static func userObject(_ user: User) -> [String: Any] {
        var object: [String: Any] = [
            "user_id": user.userId,
            "email": user.email,
        ]
        setIfPresent(&object, "phone", user.phone)
        setIfPresent(&object, "name", user.name)
        setIfPresent(&object, "plan", user.plan)
        setIfPresent(&object, "created_at", user.createdAt)
        return object
    }

    private static func productObject(_ product: Product) -> [String: Any] {
        var object: [String: Any] = ["product_id": product.productId]
        setIfPresent(&object, "url", product.url)
        setIfPresent(&object, "category", product.category)
        setIfPresent(&object, "brand", product.brand)
        object["variants"] = product.variants.map(variantObject)
        return object
    }

    private static func variantObject(_ variant: ProductVariant) -> [String: Any] {
        var object: [String: Any] = [
            "sku": variant.sku,
            "price": variant.price,
        ]
        setIfPresent(&object, "name", variant.name)
        setIfPresent(&object, "url", variant.url)
        setIfPresent(&object, "image_url", variant.imageUrl)
        setIfPresent(&object, "price_from", variant.priceFrom)
        setIfPresent(&object, "stock", variant.stock)
        setIfPresent(&object, "available", variant.available)
        setIfPresent(&object, "properties", variant.properties.map(freeFormObject))
        setIfPresent(&object, "recovery_properties", variant.recoveryProperties.map(freeFormObject))
        return object
    }

    private static func cartItemObject(_ item: CartItem) -> [String: Any] {
        var object: [String: Any] = [
            "product_id": item.productId,
            "sku": item.sku,
            "quantity": item.quantity,
            "price": item.price,
        ]
        setIfPresent(&object, "name", item.name)
        setIfPresent(&object, "price_from", item.priceFrom)
        setIfPresent(&object, "category", item.category)
        setIfPresent(&object, "brand", item.brand)
        setIfPresent(&object, "url", item.url)
        setIfPresent(&object, "image_url", item.imageUrl)
        setIfPresent(&object, "properties", item.properties.map(freeFormObject))
        setIfPresent(&object, "recovery_properties", item.recoveryProperties.map(freeFormObject))
        return object
    }

    private static func addressObject(_ address: Address) -> [String: Any] {
        var object = [String: Any]()
        setIfPresent(&object, "postal_code", address.postalCode)
        setIfPresent(&object, "address_line1", address.addressLine1)
        setIfPresent(&object, "address_number", address.addressNumber)
        setIfPresent(&object, "address_line2", address.addressLine2)
        setIfPresent(&object, "city", address.city)
        setIfPresent(&object, "state", address.state)
        setIfPresent(&object, "country", address.country)
        setIfPresent(&object, "neighborhood", address.neighborhood)
        return object
    }

    private static func cartObject(_ cart: Cart) -> [String: Any] {
        var object: [String: Any] = [
            "cart_id": cart.cartId,
            "subtotal": cart.subtotal,
            "total": cart.total,
            "freight": cart.freight,
            "tax": cart.tax,
            "discounts": cart.discounts,
        ]
        setIfPresent(&object, "currency", cart.currency)
        setIfPresent(&object, "coupons", cart.coupons)
        setIfPresent(&object, "items", cart.items.map { $0.map(cartItemObject) })
        setIfPresent(&object, "delivery_address", cart.deliveryAddress.map(addressObject))
        return object
    }

    private static func orderObject(_ order: Order) -> [String: Any] {
        var object: [String: Any] = ["cart_id": order.cartId]
        setIfPresent(&object, "order_id", order.orderId)
        object["subtotal"] = order.subtotal
        object["total"] = order.total
        object["freight"] = order.freight
        object["tax"] = order.tax
        object["discounts"] = order.discounts
        setIfPresent(&object, "currency", order.currency)
        setIfPresent(&object, "coupons", order.coupons)
        setIfPresent(&object, "items", order.items.map { $0.map(cartItemObject) })
        setIfPresent(&object, "delivery_address", order.deliveryAddress.map(addressObject))
        setIfPresent(&object, "payment_methods", order.paymentMethods.map { methods in
            methods.map { ["type": $0.type, "amount": $0.amount] as [String: Any] }
        })
        setIfPresent(&object, "delivery_methods", order.deliveryMethods.map { methods in
            methods.map { ["type": $0.type, "amount": $0.amount] as [String: Any] }
        })
        return object
    }

    /// Sets `value` only when non-nil; nils are omitted entirely from the wire.
    private static func setIfPresent(_ object: inout [String: Any], _ key: String, _ value: Any?) {
        if let value { object[key] = value }
    }

    /// Free-form `properties` / `recovery_properties`: keys untouched, `.null` entries dropped.
    private static func freeFormObject(_ map: [String: JSONValue]) -> [String: Any] {
        JSONValue.object(map).foundationValue as? [String: Any] ?? [:]
    }
}
