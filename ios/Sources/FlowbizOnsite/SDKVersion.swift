import Foundation

enum SDKVersion {
    /// Kept in lockstep with the Android SDK.
    static let current = "0.1.0"

    /// Tracker vendor identifier sent in the wire envelope (`context.vendor`).
    static let vendor = "flowbiz-ios-sdk"
}
