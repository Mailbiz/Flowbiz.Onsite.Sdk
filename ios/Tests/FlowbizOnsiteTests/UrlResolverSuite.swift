// Spec §5 resolver table.
#if canImport(Testing)
import Testing
@testable import FlowbizOnsite

@Suite struct UrlResolverSuite {

    private let base = "https://store.com"

    @Test func nilAndEmptyAreOmitted() {
        #expect(UrlResolver.resolve(nil, baseUri: base) == nil)
        #expect(UrlResolver.resolve("", baseUri: base) == nil)
        #expect(UrlResolver.resolve("   ", baseUri: base) == nil)
    }

    @Test(arguments: [
        "https://other.com/p", "http://legacy.com/p", "HTTPS://Store.com/x", "mailto:a@b.c",
        "myapp://cart", "https://store.com/p?utm_source=x#frag",
    ])
    func valuesWithASchemePassThrough(value: String) {
        #expect(UrlResolver.resolve(value, baseUri: base) == value)
    }

    @Test func protocolRelativeGetsHttps() {
        #expect(UrlResolver.resolve("//cdn.store.com/a.jpg", baseUri: base) == "https://cdn.store.com/a.jpg")
        #expect(UrlResolver.resolve("//cdn.store.com/a.jpg", baseUri: nil) == "https://cdn.store.com/a.jpg")
    }

    @Test func rootedPathIsAppendedToBase() {
        #expect(UrlResolver.resolve("/checkout", baseUri: base) == "https://store.com/checkout")
        #expect(UrlResolver.resolve("/p/1?ref=home#top", baseUri: base) == "https://store.com/p/1?ref=home#top")
    }

    @Test func barePathGetsASlash() {
        #expect(UrlResolver.resolve("checkout", baseUri: base) == "https://store.com/checkout")
        #expect(UrlResolver.resolve("p/1?x=a:b", baseUri: base) == "https://store.com/p/1?x=a:b")
    }

    @Test func trailingSlashOnBaseIsTolerated() {
        #expect(UrlResolver.resolve("/checkout", baseUri: "https://store.com/") == "https://store.com/checkout")
    }

    @Test func withoutBasePathsPassThrough() {
        #expect(UrlResolver.resolve("/checkout", baseUri: nil) == "/checkout")
        #expect(UrlResolver.resolve("checkout", baseUri: "") == "checkout")
    }

    @Test func whitespaceIsTrimmed() {
        #expect(UrlResolver.resolve("  /checkout \n", baseUri: base) == "https://store.com/checkout")
    }
}
#endif
