// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Printquee",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Printquee", targets: ["HandyShare"])
    ],
    targets: [
        .executableTarget(
            name: "HandyShare",
            path: "Sources/HandyShare",
            swiftSettings: [
                .unsafeFlags(["-swift-version", "5"])
            ]
        )
    ]
)
