import Foundation
@testable import FlowbizOnsite

/// Test-side helpers for the shared drift-guard fixtures (`shared/fixtures/`):
/// locating the fixture directory, mapping fixture `input` JSON onto the typed
/// constructors, and structural JSON comparison.
enum FixtureSupport {

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// `shared/<name>` resolved relative to this source file
    /// (`ios/Tests/FlowbizOnsiteTests/` → repo root → `shared/<name>`).
    static func sharedDirectory(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FixtureSupport.swift
            .deletingLastPathComponent() // FlowbizOnsiteTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ios
            .appendingPathComponent("shared/\(name)", isDirectory: true)
    }

    static func fixturesDirectory() -> URL {
        sharedDirectory("fixtures")
    }

    static func fixtureFiles() throws -> [URL] {
        let directory = fixturesDirectory()
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func loadFixture(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError("\(url.lastPathComponent): root is not an object")
        }
        return object
    }

    /// Maps a fixture (`event` name + camelCase `input`) onto the typed constructors.
    static func buildEvent(_ eventName: String, input: [String: Any]) throws -> Event {
        switch eventName {
        case "pageView":
            return .pageView(path: input["path"] as? String, title: input["title"] as? String)
        case "accountLogin":
            return .accountLogin(user: try user(try object(input, "user")))
        case "accountSync":
            return .accountSync(user: try user(try object(input, "user")))
        case "productView":
            return .productView(product: try product(try object(input, "product")))
        case "cartSync":
            return .cartSync(cart: try cart(try object(input, "cart")))
        case "addToCart":
            return .addToCart(products: try objectArray(input, "products").map(cartItem))
        case "cartItemUpdate":
            return .cartItemUpdate(
                cartId: try string(input, "cartId"),
                productId: try string(input, "productId"),
                sku: try string(input, "sku"),
                quantity: try int(input, "quantity")
            )
        case "cartSetPostalCode":
            return .cartSetPostalCode(
                cartId: try string(input, "cartId"),
                postalCode: try string(input, "postalCode")
            )
        case "cartSetCoupon":
            return .cartSetCoupon(
                cartId: try string(input, "cartId"),
                coupon: try string(input, "coupon")
            )
        case "checkoutStep":
            let json = try object(input, "checkout")
            return .checkoutStep(checkout: Checkout(
                cartId: try string(json, "cartId"),
                step: try int(json, "step"),
                totalSteps: try int(json, "totalSteps"),
                stepName: try string(json, "stepName")
            ))
        case "orderComplete":
            return .orderComplete(order: try order(try object(input, "order")))
        case "orderCancel":
            return .orderCancel(
                orderId: input["orderId"] as? String,
                cartId: input["cartId"] as? String
            )
        default:
            throw FixtureError("unknown fixture event: \(eventName)")
        }
    }

    private static func user(_ json: [String: Any]) throws -> User {
        User(
            userId: try string(json, "userId"),
            email: try string(json, "email"),
            phone: json["phone"] as? String,
            name: json["name"] as? String,
            plan: json["plan"] as? String,
            createdAt: json["createdAt"] as? String
        )
    }

    private static func product(_ json: [String: Any]) throws -> Product {
        Product(
            productId: try string(json, "productId"),
            url: json["url"] as? String,
            category: json["category"] as? String,
            brand: json["brand"] as? String,
            variants: try objectArray(json, "variants").map(variant)
        )
    }

    private static func variant(_ json: [String: Any]) throws -> ProductVariant {
        ProductVariant(
            sku: try string(json, "sku"),
            price: try double(json, "price"),
            name: json["name"] as? String,
            url: json["url"] as? String,
            imageUrl: json["imageUrl"] as? String,
            priceFrom: doubleOrNil(json, "priceFrom"),
            stock: intOrNil(json, "stock"),
            available: boolOrNil(json, "available"),
            properties: try propertiesOrNil(json, "properties"),
            recoveryProperties: try propertiesOrNil(json, "recoveryProperties")
        )
    }

    private static func cartItem(_ json: [String: Any]) throws -> CartItem {
        CartItem(
            productId: try string(json, "productId"),
            sku: try string(json, "sku"),
            quantity: try int(json, "quantity"),
            price: try double(json, "price"),
            name: json["name"] as? String,
            priceFrom: doubleOrNil(json, "priceFrom"),
            category: json["category"] as? String,
            brand: json["brand"] as? String,
            url: json["url"] as? String,
            imageUrl: json["imageUrl"] as? String,
            properties: try propertiesOrNil(json, "properties"),
            recoveryProperties: try propertiesOrNil(json, "recoveryProperties")
        )
    }

    private static func address(_ json: [String: Any]) -> Address {
        Address(
            postalCode: json["postalCode"] as? String,
            addressLine1: json["addressLine1"] as? String,
            addressNumber: json["addressNumber"] as? String,
            addressLine2: json["addressLine2"] as? String,
            city: json["city"] as? String,
            state: json["state"] as? String,
            country: json["country"] as? String,
            neighborhood: json["neighborhood"] as? String
        )
    }

    private static func cart(_ json: [String: Any]) throws -> Cart {
        Cart(
            cartId: try string(json, "cartId"),
            subtotal: try double(json, "subtotal"),
            total: try double(json, "total"),
            freight: try double(json, "freight"),
            tax: try double(json, "tax"),
            discounts: try double(json, "discounts"),
            currency: json["currency"] as? String,
            coupons: json["coupons"] as? [String],
            items: try (json["items"] as? [[String: Any]]).map { try $0.map(cartItem) },
            deliveryAddress: (json["deliveryAddress"] as? [String: Any]).map(address)
        )
    }

    private static func order(_ json: [String: Any]) throws -> Order {
        Order(
            cartId: try string(json, "cartId"),
            orderId: json["orderId"] as? String,
            subtotal: try double(json, "subtotal"),
            total: try double(json, "total"),
            freight: try double(json, "freight"),
            tax: try double(json, "tax"),
            discounts: try double(json, "discounts"),
            currency: json["currency"] as? String,
            coupons: json["coupons"] as? [String],
            items: try (json["items"] as? [[String: Any]]).map { try $0.map(cartItem) },
            deliveryAddress: (json["deliveryAddress"] as? [String: Any]).map(address),
            paymentMethods: try (json["paymentMethods"] as? [[String: Any]]).map { methods in
                try methods.map { PaymentMethod(type: try string($0, "type"), amount: try double($0, "amount")) }
            },
            deliveryMethods: try (json["deliveryMethods"] as? [[String: Any]]).map { methods in
                try methods.map { DeliveryMethod(type: try string($0, "type"), amount: try double($0, "amount")) }
            }
        )
    }

    // MARK: - JSON → JSONValue

    private static func propertiesOrNil(_ json: [String: Any], _ key: String) throws -> [String: JSONValue]? {
        guard let raw = json[key] as? [String: Any] else { return nil }
        var result = [String: JSONValue]()
        for (name, value) in raw {
            result[name] = try jsonValue(value)
        }
        return result
    }

    private static func jsonValue(_ any: Any) throws -> JSONValue {
        switch any {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            return isBoolean(number) ? .bool(number.boolValue) : .number(number.doubleValue)
        case is NSNull:
            return .null
        case let array as [Any]:
            return .array(try array.map(jsonValue))
        case let object as [String: Any]:
            var entries = [String: JSONValue]()
            for (key, value) in object { entries[key] = try jsonValue(value) }
            return .object(entries)
        default:
            throw FixtureError("unsupported JSON value: \(any)")
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - Structural comparison

    /// Structural comparison — key order irrelevant, numbers compared by
    /// double value (`0` == `0.0`). Returns a description of the first
    /// difference, or nil when equivalent.
    static func diff(expected: Any, actual: Any, path: String) -> String? {
        switch (expected, actual) {
        case (is NSNull, is NSNull):
            return nil
        case (let exp as [String: Any], let act as [String: Any]):
            let expKeys = Set(exp.keys)
            let actKeys = Set(act.keys)
            guard expKeys == actKeys else {
                let missing = expKeys.subtracting(actKeys).sorted()
                let extra = actKeys.subtracting(expKeys).sorted()
                return "\(path): key mismatch (missing=\(missing), unexpected=\(extra))"
            }
            for key in expKeys.sorted() {
                if let difference = diff(expected: exp[key]!, actual: act[key]!, path: "\(path).\(key)") {
                    return difference
                }
            }
            return nil
        case (let exp as [Any], let act as [Any]):
            guard exp.count == act.count else {
                return "\(path): array length \(exp.count) != \(act.count)"
            }
            for (index, pair) in zip(exp, act).enumerated() {
                if let difference = diff(expected: pair.0, actual: pair.1, path: "\(path)[\(index)]") {
                    return difference
                }
            }
            return nil
        case (let exp as NSNumber, let act as NSNumber):
            if isBoolean(exp) != isBoolean(act) {
                return "\(path): boolean/number type mismatch (expected \(exp), was \(act))"
            }
            if isBoolean(exp) {
                return exp.boolValue == act.boolValue ? nil : "\(path): expected \(exp) but was \(act)"
            }
            return exp.doubleValue == act.doubleValue ? nil : "\(path): expected \(exp) but was \(act)"
        case (let exp as String, let act as String):
            return exp == act ? nil : "\(path): expected '\(exp)' but was '\(act)'"
        default:
            return "\(path): type mismatch (expected \(type(of: expected)), was \(type(of: actual)))"
        }
    }

    // MARK: - Extraction helpers

    private static func object(_ json: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = json[key] as? [String: Any] else {
            throw FixtureError("missing object '\(key)'")
        }
        return value
    }

    private static func objectArray(_ json: [String: Any], _ key: String) throws -> [[String: Any]] {
        guard let value = json[key] as? [[String: Any]] else {
            throw FixtureError("missing object array '\(key)'")
        }
        return value
    }

    private static func string(_ json: [String: Any], _ key: String) throws -> String {
        guard let value = json[key] as? String else {
            throw FixtureError("missing string '\(key)'")
        }
        return value
    }

    private static func double(_ json: [String: Any], _ key: String) throws -> Double {
        guard let value = json[key] as? NSNumber, !isBoolean(value) else {
            throw FixtureError("missing number '\(key)'")
        }
        return value.doubleValue
    }

    private static func int(_ json: [String: Any], _ key: String) throws -> Int {
        guard let value = json[key] as? NSNumber, !isBoolean(value) else {
            throw FixtureError("missing number '\(key)'")
        }
        return value.intValue
    }

    private static func doubleOrNil(_ json: [String: Any], _ key: String) -> Double? {
        guard let value = json[key] as? NSNumber, !isBoolean(value) else { return nil }
        return value.doubleValue
    }

    private static func intOrNil(_ json: [String: Any], _ key: String) -> Int? {
        guard let value = json[key] as? NSNumber, !isBoolean(value) else { return nil }
        return value.intValue
    }

    private static func boolOrNil(_ json: [String: Any], _ key: String) -> Bool? {
        guard let value = json[key] as? NSNumber, isBoolean(value) else { return nil }
        return value.boolValue
    }
}
