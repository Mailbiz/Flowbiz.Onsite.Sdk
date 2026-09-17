package br.com.flowbiz.onsite

/** Internal SDK version constants, stamped into every envelope by [FlowbizCore]. */
internal object SdkVersion {
    /** Semantic version of the SDK. Kept in lockstep with the iOS SDK. */
    const val CURRENT: String = "0.1.0"

    /** Tracker vendor identifier sent in the wire envelope (`context.vendor`). */
    const val VENDOR: String = "flowbiz-android-sdk"
}
