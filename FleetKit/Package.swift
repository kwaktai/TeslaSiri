// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FleetKit",
    platforms: [
        .iOS("27.3"),
        .macOS("27.3")
    ],
    products: [
        .library(name: "FleetKit", targets: ["FleetKit"])
    ],
    dependencies: [
        .package(path: "../TeslaFleetTransport")
    ],
    targets: [
        .target(name: "FleetKit", dependencies: ["TeslaFleetTransport"]),
        .testTarget(name: "FleetKitTests", dependencies: ["FleetKit"])
    ]
)
