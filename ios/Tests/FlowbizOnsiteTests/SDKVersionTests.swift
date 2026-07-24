// XCTest suite — runs wherever XCTest is available (Xcode hosts, CI).
// Guarded because Command Line Tools-only hosts ship Swift Testing but not
// XCTest; the equivalent Swift Testing suite lives in SDKVersionSuite.swift.
#if canImport(XCTest)
import XCTest
@testable import FlowbizOnsite

final class SDKVersionTests: XCTestCase {
    func testVersionIsSemver() {
        let parts = SDKVersion.current.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }

    func testVendorIdentifier() {
        XCTAssertEqual(SDKVersion.vendor, "flowbiz-ios-sdk")
    }
}
#endif
