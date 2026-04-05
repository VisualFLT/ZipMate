// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZipMate",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ZipMate", targets: ["SevenZipMacUI"])
    ],
    targets: [
        .executableTarget(
            name: "SevenZipMacUI",
            path: "Sources/SevenZipMacUI",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
