// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "JellyfinBooksCore",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [.library(name: "BookCore", targets: ["BookCore"])],
    dependencies: [.package(url: "https://github.com/jellyfin/jellyfin-sdk-swift.git", exact: "3.1.0")],
    targets: [
        .target(name: "BookCore", dependencies: [.product(name: "JellyfinAPI", package: "jellyfin-sdk-swift")], path: "App", exclude: ["UI", "Readers", "Resources", "JellyfinBooksApp.swift"], sources: ["Core", "Jellyfin"]),
        .testTarget(name: "BookCoreTests", dependencies: ["BookCore"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
