// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LBRYKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LBRYKit", targets: ["LBRYKit"])
    ],
    dependencies: [
        // Only used off Apple platforms (CI on Linux); iOS/macOS use CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        // Bitcoin Core's libsecp256k1. Only its C API is used (the Swift layer is marked unstable).
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.24.0"),
    ],
    targets: [
        .target(
            name: "LBRYKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .product(name: "libsecp256k1", package: "swift-secp256k1"),
            ]
        ),
        .testTarget(
            name: "LBRYKitTests",
            dependencies: ["LBRYKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
