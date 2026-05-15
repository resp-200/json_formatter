// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JSONFormatterApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "JSONFormatterApp", targets: ["JSONFormatterApp"])
    ],
    targets: [
        .executableTarget(
            name: "JSONFormatterApp",
            path: "Sources/JSONFormatterApp"
        )
    ]
)
