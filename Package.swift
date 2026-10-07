// swift-tools-version: 5.9
import PackageDescription

// Not unsafeFlags, which would make the package unusable as a dependency.
let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency")
]

let package = Package(
    name: "FlowbizOnsite",
    platforms: [
        // Kept pending merchant device-share data; revisit iOS 15 before 1.0.
        .iOS(.v13),
        // Only so the package builds and tests on macOS hosts; the product ships for iOS.
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
            // Bundled so host apps' privacy reports aggregate it; .copy keeps the file verbatim.
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
