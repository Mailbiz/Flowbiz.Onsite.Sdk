// swift-tools-version: 5.9
import PackageDescription

// SPEC §3: warning-clean under strict concurrency checking. Expressed as an
// upcoming-feature flag (no `unsafeFlags`, which would make the package
// ineligible as a downstream dependency); on Swift 6 toolchains this enables
// complete checking while staying in the Swift 5 language mode of
// tools-version 5.9.
let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency")
]

let package = Package(
    name: "FlowbizOnsite",
    platforms: [
        .iOS(.v13),
        // macOS entry exists only so the package builds/tests on macOS hosts
        // (CI, local dev); the shipped product targets iOS 13+.
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "FlowbizOnsite",
            targets: ["FlowbizOnsite"]
        )
    ],
    targets: [
        .target(
            name: "FlowbizOnsite",
            path: "ios/Sources/FlowbizOnsite",
            // SPEC §12: the privacy manifest ships inside the target's
            // resource bundle so host apps' privacy reports aggregate the
            // SDK's declarations. `.copy` keeps the file verbatim (no plist
            // processing); no code reads it, so `Bundle.module` availability
            // is irrelevant beyond the bundle existing.
            resources: [
                .copy("PrivacyInfo.xcprivacy")
            ],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "FlowbizOnsiteTests",
            dependencies: ["FlowbizOnsite"],
            path: "ios/Tests/FlowbizOnsiteTests",
            swiftSettings: strictConcurrency
        )
    ]
)
