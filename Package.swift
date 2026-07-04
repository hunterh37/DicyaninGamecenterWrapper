// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DicyaninGamecenterWrapper",
    platforms: [
        .visionOS(.v2),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "DicyaninGamecenterWrapper",
            targets: ["DicyaninGamecenterWrapper"]
        )
    ],
    targets: [
        .target(
            name: "DicyaninGamecenterWrapper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DicyaninGamecenterWrapperTests",
            dependencies: ["DicyaninGamecenterWrapper"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
