// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OmniBLECore",
    platforms: [
        .macOS(.v13),
        .iOS(.v15),
        // watchOS(.v7) to match Loop's WatchApp Extension deployment target
        // (the package floor must not exceed the app's). The driver uses no
        // watchOS-8-only APIs.
        .watchOS(.v7)
    ],
    products: [
        .library(name: "OmniBLECore", targets: ["OmniBLECore"]),
    ],
    dependencies: [
        // 1.7.1 to match the LoopWorkspace pin so integrating OmniBLECore into
        // Loop's watch app doesn't force a workspace-wide CryptoSwift bump. Only
        // AES/CBC/CMAC are used, all present well before 1.8.0.
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", "1.7.1"..<"2.0.0"),
    ],
    targets: [
        // Minimal shim standing in for LoopKit. Named "OmniBLEShim" (NOT "LoopKit")
        // so it does not collide with the REAL LoopKit.framework when OmniBLECore
        // is linked into Loop's WatchApp Extension. Provides only the handful of
        // types the portable driver core touches; none are exposed in the public
        // facade, so this shim stays entirely internal to the package.
        .target(
            name: "OmniBLEShim",
            path: "Sources/LoopKitShim",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "OmniBLECore",
            dependencies: [
                "OmniBLEShim",
                .product(name: "CryptoSwift", package: "CryptoSwift"),
            ],
            path: "Sources/OmniBLECore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OmniBLECoreTests",
            dependencies: ["OmniBLECore"],
            path: "Tests/OmniBLECoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
