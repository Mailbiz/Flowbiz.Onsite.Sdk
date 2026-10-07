// Guarded: Command Line Tools ship Swift Testing but not XCTest; SDKVersionSuite mirrors this suite.
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
