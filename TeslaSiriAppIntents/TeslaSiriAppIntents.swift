import AppIntents
import FleetKit

/// Surfaces the App Intents defined in the shared `FleetKit` package to this
/// extension so the system can perform them in the extension's process.
extension TeslaSiriAppIntentsExtension: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [FleetKitPackage.self]
    }
}
