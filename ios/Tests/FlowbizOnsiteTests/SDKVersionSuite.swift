// Swift Testing suite — mirrors SDKVersionTests.swift so the package tests
// green on hosts that have the Testing framework but not XCTest.
#if canImport(Testing)
import Testing
@testable import FlowbizOnsite

@Suite struct SDKVersionSuite {
    @Test func versionIsSemver() {
        let parts = SDKVersion.current.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }

    @Test func vendorIdentifier() {
        #expect(SDKVersion.vendor == "flowbiz-ios-sdk")
    }
}
#endif
