#if canImport(Testing)
import Testing
@testable import FlowbizOnsite

// The shared account_* fixtures pin the wire; these pin what a fixture cannot say.
@Suite struct UserSanitizerSuite {

    @Test func anEmailIsJudgedAsTheWebLooksLikeEmailDoes() {
        for email in ["a@b.co", "maria+tag@sub.gmail.com", "x@xn--80ak6aa92e.xn--p1ai"] {
            #expect(UserSanitizer.looksLikeEmail(email), "\(email)")
        }
        // The trailing line break: JS `$` does not match before it, an ICU `$` would.
        for email in ["", "maria", "maria@gmail", "maria@gmail.c", "a.b@gmail", "maria@gmail.com\n", "ma ria@gmail.com"] {
            #expect(!UserSanitizer.looksLikeEmail(email), "\(email)")
        }
    }

    @Test func aUserIdThatIdentifiesNobodyIsLeftOut() {
        for userId in ["0", "-1", "null", "Undefined", "none", "NaN", " 7 ", "vrn--vtexsphinx", "maria@gmail"] {
            #expect(UserSanitizer.sanitize(User(userId: userId)) == nil, "\(userId)")
        }
        #expect(UserSanitizer.sanitize(User(userId: "10")) == User(userId: "10"))
    }

    @Test func otherEventsAndFieldsPassThroughUntouched() {
        let page = Event.pageView(path: "/Home", title: "Home")
        #expect(UserSanitizer.sanitize(page) == page)
        let user = User(userId: "U-1", phone: "+55 11", name: "Maria Oliveira", plan: "VIP", createdAt: "2024-03-15T14:22:00Z")
        let expected = User(userId: "u-1", phone: "+55 11", name: "Maria Oliveira", plan: "VIP", createdAt: "2024-03-15T14:22:00Z")
        #expect(UserSanitizer.sanitize(.accountSync(user: user)) == .accountSync(user: expected))
    }
}
#endif
