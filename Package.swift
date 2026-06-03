// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Airmessage",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Airmessage",
            path: "Sources/Airmessage"
        )
    ]
)
