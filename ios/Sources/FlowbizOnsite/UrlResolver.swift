import Foundation

/// Spec §5: resolves app-supplied URL-shaped values against the configured
/// `baseUri`. Pure. Applied by `EventSerializer` to page, product, variant
/// and cart-item URLs, and by `FlowbizCore` to the remembered page URL.
///
/// | input | output |
/// |---|---|
/// | nil / blank | nil |
/// | has a scheme | unchanged |
/// | `//host/...` | `https:` + value |
/// | `/path`, base set | base + value |
/// | `path`, base set | base + `/` + value |
/// | base nil/empty | unchanged |
enum UrlResolver {

    static func resolve(_ value: String?, baseUri: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if hasScheme(trimmed) { return trimmed }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        var base = (baseUri ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.isEmpty { return trimmed }
        return trimmed.hasPrefix("/") ? base + trimmed : base + "/" + trimmed
    }

    /// RFC 3986 scheme: `^[A-Za-z][A-Za-z0-9+.-]*:`.
    private static func hasScheme(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil
    }
}
