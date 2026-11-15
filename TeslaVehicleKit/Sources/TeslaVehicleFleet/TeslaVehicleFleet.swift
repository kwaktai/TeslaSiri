import Foundation

/// Bundled vehicle library: one folder per exported build plus the shared Classic
/// material banks. Pass `directory` to `VehicleLibrary(directory:)`.
public enum TeslaVehicleFleet {
    public static var directory: URL {
        Bundle.module.url(forResource: "Fleet", withExtension: nil)
            ?? Bundle.module.bundleURL.appendingPathComponent("Fleet", isDirectory: true)
    }
}
