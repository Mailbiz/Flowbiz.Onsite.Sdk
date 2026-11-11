import Foundation

// The web's account pipeline: the universal vendor's userSchema lowercases, then onsite-core's
// sanitizeAccountUser drops an invalid email and a user_id that identifies nobody.
enum UserSanitizer {

    /// The event as the web would send it, or nil when an account event is left with no valid user_id or email.
    static func sanitize(_ event: Event) -> Event? {
        switch event {
        case .accountLogin(let user): return sanitize(user).map { .accountLogin(user: $0) }
        case .accountSync(let user): return sanitize(user).map { .accountSync(user: $0) }
        default: return event
        }
    }

    static func sanitize(_ user: User) -> User? {
        let email = user.email.map { $0.lowercased() }.flatMap { looksLikeEmail($0) ? $0 : nil }
        let userId = user.userId.map { $0.lowercased() }.flatMap {
            isValidUserId($0) && !isEmailOtherThan($0, email) ? $0 : nil
        }
        if userId == nil && email == nil { return nil }
        return User(
            userId: userId, email: email, phone: user.phone, name: user.name, plan: user.plan, createdAt: user.createdAt
        )
    }

    /// Web `setUserId(user_id || email)`.
    static func identityUserId(_ user: User) -> String? {
        user.userId ?? user.email
    }

    private static let email = "^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:\\.[a-zA-Z0-9-]+)*\\z"
    private static let emailTopLevelDomain = "\\.(?:[a-zA-Z]{2,}|xn--[a-zA-Z0-9-]+)\\z"
    private static let userIdPlaceholders: Set<String> = ["0", "-1", "null", "undefined", "none", "nan"]
    private static let vtexAppPrincipalPrefix = "vrn--"

    static func looksLikeEmail(_ value: String) -> Bool {
        guard let at = value.firstIndex(of: "@"), let dot = value.lastIndex(of: "."), at < dot else { return false }
        return value.range(of: email, options: .regularExpression) != nil
            && value.range(of: emailTopLevelDomain, options: .regularExpression) != nil
    }

    private static func isValidUserId(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isMalformedEmail = value.contains("@") && !looksLikeEmail(value)
        return normalized.count > 1 && !userIdPlaceholders.contains(normalized)
            && !normalized.hasPrefix(vtexAppPrincipalPrefix) && !isMalformedEmail
    }

    private static func isEmailOtherThan(_ value: String, _ email: String?) -> Bool {
        guard let email else { return false }
        return value.contains("@") && value.lowercased() != email.lowercased()
    }
}
