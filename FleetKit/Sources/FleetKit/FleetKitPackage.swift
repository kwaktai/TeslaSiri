import AppIntents

/// Declares the App Intents defined in this Swift package so that targets which
/// link `FleetKit` can surface them to the system. The app and the App Intents
/// extension reference this type from their `AppIntentsPackage` conformance.
public struct FleetKitPackage: AppIntentsPackage {}
