// swift-tools-version: 5.9
import PackageDescription

// An upcoming-feature flag, not `unsafeFlags` (which would make the package
// unusable as a dependency): complete checking on Swift 6 toolchains, still in
// the Swift 5 language mode.
let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency")
]

let package = Package(
    name: "FlowbizOnsite",
    platforms: [
        // Kept pending merchant device-share data; revisit iOS 15 before 1.0.
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
            // In the resource bundle so host apps' privacy reports aggregate
            // it; `.copy` keeps the file verbatim.
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
