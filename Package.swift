// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ergokeys",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ergokeys"),
    ]
)
