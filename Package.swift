// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sinampay",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Sinampay", path: "Sources/Sinampay")
    ]
)
