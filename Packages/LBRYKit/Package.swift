// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LBRYKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LBRYKit", targets: ["LBRYKit"])
    ],
    targets: [
        .target(name: "LBRYKit"),
        .testTarget(
            name: "LBRYKitTests",
            dependencies: ["LBRYKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
