// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SecureKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "SecureCore", targets: ["SecureCore"]),
        .library(name: "SecureStore", targets: ["SecureStore"]),
        .library(name: "SecureDevice", targets: ["SecureDevice"]),
        .library(name: "SecureConnect", targets: ["SecureConnect"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.19.0"),
    ],
    targets: [
        // Pure logic: money, canonical encoding, hash chain, protocol messages, budget engine.
        .target(name: "SecureCore"),
        // Simulated connected features: banks, practice markets, sports, strategies, responsible play. Offline, pure Swift.
        .target(name: "SecureConnect", dependencies: ["SecureCore"]),
        // Encrypted persistence on SQLCipher.
        .target(
            name: "SecureStore",
            dependencies: [
                "SecureCore",
                "SecureConnect",
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
            ]
        ),
        // Keychain, Secure Enclave, Face ID, notifications.
        .target(name: "SecureDevice", dependencies: ["SecureCore"]),
        .testTarget(name: "SecureCoreTests", dependencies: ["SecureCore"]),
        .testTarget(name: "SecureConnectTests", dependencies: ["SecureConnect", "SecureCore"]),
        .testTarget(name: "SecureStoreTests", dependencies: ["SecureStore", "SecureConnect", "SecureCore"]),
    ]
)
