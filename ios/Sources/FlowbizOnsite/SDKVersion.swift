import Foundation

/// Internal SDK version constants, stamped into every envelope by `FlowbizCore`.
enum SDKVersion {
    /// Semantic version of the SDK. Kept in lockstep with the Android SDK.
    static let current = "0.1.0"

    /// Tracker vendor identifier sent in the wire envelope (`context.vendor`).
    static let vendor = "flowbiz-ios-sdk"
}
