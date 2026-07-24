// swift-tools-version: 5.9
import PackageDescription

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
            path: "ios/Sources/FlowbizOnsite"
        ),
        .testTarget(
            name: "FlowbizOnsiteTests",
            dependencies: ["FlowbizOnsite"],
            path: "ios/Tests/FlowbizOnsiteTests"
        )
    ]
)
