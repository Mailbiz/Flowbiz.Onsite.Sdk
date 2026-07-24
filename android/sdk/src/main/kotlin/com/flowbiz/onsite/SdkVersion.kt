package com.flowbiz.onsite

/**
 * Internal SDK version constants. Placeholder for Slice 0 — the real SDK
 * surface (`Flowbiz`, `FlowbizConfig`, ...) is built in later slices.
 */
internal object SdkVersion {
    /** Semantic version of the SDK. Kept in lockstep with the iOS SDK. */
    const val CURRENT: String = "0.1.0"

    /** Tracker vendor identifier sent in the wire envelope (`context.vendor`). */
    const val VENDOR: String = "flowbiz-android-sdk"
}
