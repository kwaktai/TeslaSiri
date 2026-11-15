# Wattie

Wattie is an independent SwiftUI app for viewing and controlling Tesla vehicles through Tessie. It combines a live vehicle dashboard, drive and charging history, and vehicle controls in Siri and Shortcuts. The Xcode project and app target are named `TeslaSiri`.

The 3D showroom started as an experiment to see how closely RealityKit could reproduce the vehicle rendering in Tesla's Android app. The extracted models were converted to USD and animated using vehicle telemetry. The same renderer powers the showroom and replays recorded drives.

## Run locally

1. Open [`TeslaSiri.xcodeproj`](TeslaSiri.xcodeproj/) in Xcode 27.3 or later and select the `TeslaSiri` scheme and an iOS 27.3 or later simulator or device. For device builds, set your signing team and bundle IDs on the app and its extension. Use matching App Group and keychain access group entitlements in both targets, and update the App Group ID in [`FleetKitConfig.swift`](FleetKit/Sources/FleetKit/FleetKitConfig.swift).
2. Run the app and choose **Demo Car** under **Diagnostics → Siri & Command Sandbox** to explore without a Tessie account.
3. For live data and controls, generate an access token under **Settings → Developer** in Tessie and paste it into the connection card in Wattie. Wattie stores the token in Keychain. [Tessie token setup](https://help.tessie.com/article/29-use-google-home-assistant-tesla)

## Project layout

- [`TeslaSiri/`](TeslaSiri/) contains the SwiftUI app, Tessie client, and RealityKit showroom and drive replay.
- [`FleetKit/`](FleetKit/) contains the App Intents, Shortcuts and Spotlight integration, extension-safe Tessie client, and Swift package tests.
- [`TeslaSiriAppIntents/`](TeslaSiriAppIntents/) hosts the App Intents extension.
- [`TeslaVehicleKit/`](TeslaVehicleKit/) contains the RealityKit loader and bundles the converted Fleet resources.

See [AGENTS.md](AGENTS.md) for development and validation conventions. Keep Tessie tokens, raw vehicle exports, and signing files out of commits.

## License

The [MIT License](LICENSE) applies to the project-authored code and documentation. Tesla retains its rights to the vehicle models and related assets in the RealityKit conversions. The [third-party notices](THIRD_PARTY_NOTICES.md) identify the assets and marks excluded from the MIT grant.
