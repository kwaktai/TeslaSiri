// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FleetKit",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0")
    ],
    products: [
        .library(name: "FleetKit", targets: ["FleetKit"])
    ],
    targets: [
        .target(name: "FleetKit")
    ]
)
