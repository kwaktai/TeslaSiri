// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TeslaFleetTransport",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "TeslaFleetTransport", targets: ["TeslaFleetTransport"])
    ],
    targets: [
        .target(name: "TeslaFleetTransport"),
        .testTarget(name: "TeslaFleetTransportTests", dependencies: ["TeslaFleetTransport"])
    ]
)
