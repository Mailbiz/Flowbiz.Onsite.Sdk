// Envelope shape tests for the SPEC §4 entry produced by `EnvelopeBuilder`.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct EnvelopeSuite {

    // 2023-11-14T22:13:20 UTC
    private let createdAtMillis: Int64 = 1_700_000_000_000
    private let sentAtMillis: Int64 = 1_700_000_000_123

    private func build(
        event: Event = .cartSync(
            cart: Cart(cartId: "c-9f81b2e0", subtotal: 0, total: 0, freight: 0, tax: 0, discounts: 0)
        ),
        userId: String? = "98412"
    ) throws -> [String: Any] {
        try EnvelopeBuilder.build(
            event: event,
            hash: "7f9c31c2-6a5e-4e0f-9c1d-2b8a4d3e5f60",
            createdAtMillis: createdAtMillis,
            sentAtMillis: sentAtMillis,
            timezone: "-03:00",
            userId: userId,
            anonymousId: "a3b1c5d7-1111-4222-8333-444455556666",
            sessionId: "e9f8d7c6-7777-4888-9999-000011112222",
            visitCount: 3,
            language: "pt-BR",
            screen: "1170x2532",
            appId: "77777",
            platform: "ios",
            sdkVersion: "1.0.0"
        )
    }

    @Test func allEnvelopeFieldsPresent() throws {
        let envelope = try build()
        #expect(envelope["event"] as? String == "cart.sync")
        #expect(envelope["hash"] as? String == "7f9c31c2-6a5e-4e0f-9c1d-2b8a4d3e5f60")
        #expect(envelope["app_id"] as? String == "77777")
        #expect(envelope["platform"] as? String == "ios")
        #expect(envelope["v_tracker"] as? String == "flowbiz-ios-sdk")
        #expect(envelope["v_version"] as? String == "ios-1.0.0")

        let identity = envelope["identity"] as? [String: Any]
        #expect(identity?["user_id"] as? String == "98412")
        #expect(identity?["anonymous_id"] as? String == "a3b1c5d7-1111-4222-8333-444455556666")
        #expect(identity?["session_id"] as? String == "e9f8d7c6-7777-4888-9999-000011112222")
        #expect(identity?["visit_count"] as? Int == 3)

        let context = envelope["context"] as? [String: Any]
        #expect(context?["platform"] as? String == "ios")
        #expect(context?["language"] as? String == "pt-BR")
        #expect(context?["screen"] as? String == "1170x2532")
        #expect(context?["vendor"] as? String == "flowbiz-ios-sdk")
        #expect(context?["onsite_version"] as? String == "1.0.0")
    }

    @Test func dataIsAJSONStringNotANestedObject() throws {
        let envelope = try build()
        let data = try #require(envelope["data"] as? String, "data must be a String on the wire")
        // ... and it must parse back to the payload object.
        let parsed = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]
        let cart = parsed?["cart"] as? [String: Any]
        #expect(cart?["cart_id"] as? String == "c-9f81b2e0")
    }

    @Test func timingsAreIso8601MillisUtc() throws {
        let timings = try #require(try build()["timings"] as? [String: Any])
        #expect(timings["created_at"] as? String == "2023-11-14T22:13:20.000Z")
        #expect(timings["sent_at"] as? String == "2023-11-14T22:13:20.123Z")
        #expect(timings["timezone"] as? String == "-03:00")

        let isoMillis = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
        for key in ["created_at", "sent_at"] {
            let value = try #require(timings[key] as? String)
            #expect(value.range(of: isoMillis, options: .regularExpression) != nil)
        }
    }

    @Test func userIdOmittedWhenNil() throws {
        let identity = try #require(try build(userId: nil)["identity"] as? [String: Any])
        #expect(identity["user_id"] == nil)
        #expect(identity["anonymous_id"] != nil)
    }

    @Test func contextCarriesUrlBaseUriAndRecoveryUrlWhenGiven() throws {
        let envelope = try EnvelopeBuilder.build(
            event: .cartSetCoupon(cartId: "c-1", coupon: "X"),
            hash: "h", createdAtMillis: createdAtMillis, sentAtMillis: sentAtMillis, timezone: "-03:00",
            userId: nil, anonymousId: "a", sessionId: "s", visitCount: 1,
            language: "pt-BR", screen: "1170x2532", appId: "77777", platform: "ios", sdkVersion: "1.0.0",
            contextUrl: "https://store.com/checkout",
            baseUri: "https://store.com",
            recoveryUrl: "https://store.com/carrinho"
        )
        let context = try #require(envelope["context"] as? [String: Any])
        #expect(context["url"] as? String == "https://store.com/checkout")
        #expect(context["baseuri"] as? String == "https://store.com")
        #expect(context["recoveryUrl"] as? String == "https://store.com/carrinho")
        #expect(context["title"] == nil)
    }

    @Test func contextOmitsUrlBaseUriAndRecoveryUrlByDefault() throws {
        let context = try #require(try build(event: .pageView(path: "/checkout"))["context"] as? [String: Any])
        #expect(context["url"] == nil)
        #expect(context["baseuri"] == nil)
        #expect(context["recoveryUrl"] == nil)
    }

    @Test func emptyBaseUriIsOmitted() throws {
        let envelope = try EnvelopeBuilder.build(
            event: .cartSetCoupon(cartId: "c-1", coupon: "X"),
            hash: "h", createdAtMillis: createdAtMillis, sentAtMillis: sentAtMillis, timezone: "-03:00",
            userId: nil, anonymousId: "a", sessionId: "s", visitCount: 1,
            language: "pt-BR", screen: "1170x2532", appId: "77777", platform: "ios", sdkVersion: "1.0.0",
            baseUri: ""
        )
        #expect((envelope["context"] as? [String: Any])?["baseuri"] == nil)
    }

    /// M4: `context.url` uses the same non-empty guard as `baseuri` /
    /// `recoveryUrl` — an empty (not nil) `contextUrl` must be omitted too.
    @Test func emptyContextUrlIsOmitted() throws {
        let envelope = try EnvelopeBuilder.build(
            event: .cartSetCoupon(cartId: "c-1", coupon: "X"),
            hash: "h", createdAtMillis: createdAtMillis, sentAtMillis: sentAtMillis, timezone: "-03:00",
            userId: nil, anonymousId: "a", sessionId: "s", visitCount: 1,
            language: "pt-BR", screen: "1170x2532", appId: "77777", platform: "ios", sdkVersion: "1.0.0",
            contextUrl: ""
        )
        #expect((envelope["context"] as? [String: Any])?["url"] == nil)
    }

    @Test func buildUsesBaseUriToResolveDataUrls() throws {
        let envelope = try EnvelopeBuilder.build(
            event: .pageView(path: "/checkout", title: "Checkout"),
            hash: "h", createdAtMillis: createdAtMillis, sentAtMillis: sentAtMillis, timezone: "-03:00",
            userId: nil, anonymousId: "a", sessionId: "s", visitCount: 1,
            language: "pt-BR", screen: "1170x2532", appId: "77777", platform: "ios", sdkVersion: "1.0.0",
            baseUri: "https://store.com"
        )
        #expect(envelope["data"] as? String == #"{"page":{"title":"Checkout","url":"https://store.com/checkout"}}"#)
    }
}
#endif
