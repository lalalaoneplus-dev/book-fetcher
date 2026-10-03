// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BookFetcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BookFetcherCore", targets: ["BookFetcherCore"]),
        .executable(name: "BookFetcher", targets: ["BookFetcher"]),
        .executable(name: "BookFetcherServer", targets: ["BookFetcherServer"])
    ],
    targets: [
        .target(
            name: "BookFetcherCore",
            path: "Sources/BookFetcher",
            sources: ["Models", "Services", "Support"]
        ),
        .executableTarget(
            name: "BookFetcher",
            dependencies: ["BookFetcherCore"],
            path: "Sources/BookFetcherApp"
        ),
        .executableTarget(
            name: "BookFetcherServer",
            dependencies: ["BookFetcherCore"],
            path: "Sources/BookFetcherServer"
        ),
        .testTarget(
            name: "BookFetcherTests",
            dependencies: ["BookFetcherCore"],
            path: "Tests/BookFetcherTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
