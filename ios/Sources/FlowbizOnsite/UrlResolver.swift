import Foundation

/// Resolves app-supplied URLs against `FlowbizConfig.baseUri`.
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

    private static func hasScheme(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil
    }
}
