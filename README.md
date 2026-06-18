# TeslaSiri

TeslaSiri is a SwiftUI iOS app for viewing and controlling Tesla vehicles through [Tessie](https://tessie.com). It stores a user-provided Tessie access token in Keychain, adapts Tessie state and history into app-owned models, mirrors credentials to the App Intents extension, and keeps cached vehicle data available between refreshes.

## Project Layout

- `TeslaSiri/ContentView.swift`: SwiftUI `@main` app entry point; wires shared services into `AppRootView`.
- `TeslaSiri/UI/AppRootView.swift`: TabView shell (`AppTab` enum + `AppRootView`) and shared auth/diagnostics state.
- `TeslaSiri/UI/Dashboard/`: User-facing dashboard cards (vehicle picker, status, software, active drive, charging, cached data, sign-in banner).
- `TeslaSiri/UI/Drives/`: Drive demo: drive picker, route map, session summary, scrubber, metric tiles.
- `TeslaSiri/UI/Diagnostics/`: Tessie diagnostics, normalized data, Spotlight debugging, account.
- `TeslaSiri/UI/Shared/`: Reusable building blocks (`CardContainer`, `StatusBadge`, formatters, geocoder actor, `DiagnosticMonospacedValue`).
- `TeslaSiri/FleetAPI/FleetAPIClient.swift`: Tessie HTTP client and normalized compatibility surface.
- `TeslaSiri/FleetAPI/TessieAPIModels.swift`: Tessie DTO and model adapters.
- `TeslaSiri/FleetAPI/FleetAPIModels.swift`: Codable Fleet API model types.
- `TeslaSiri/FleetAPI/FleetDataStore.swift`: Main observable data store for bootstrap, sync, selected vehicle data, software actions, drives, routes, charging, and telemetry.
- `TeslaSiri/FleetAPI/FleetDataCache.swift`: Local Fleet data cache support.
- `TeslaSiri/FleetAPI/FleetAccessTokenKeychain.swift`: Keychain-backed Tessie token persistence.
- `TeslaSiri/FleetAPI/TessieAccessTokenStore.swift`: Token persistence and extension-mirroring facade used by the app.
- `TeslaSiri/FleetAPI/FleetNotifications.swift`: Notification payload decoding and local notification scheduling.
- `TeslaSiri/Info.plist`: App metadata and background task declarations.

## Connecting Tessie

Generate an access token in [Tessie Developer Settings](https://dash.tessie.com/settings/api), then paste it into the dashboard connection card. The app validates the token against `https://api.tessie.com`, stores it in Keychain, and mirrors only the access token plus selected VIN to the App Intents extension. Tessie does not expose the former custom notification-webhook management API, so that developer UI is intentionally not part of the active diagnostics screen.

## Development

Open `TeslaSiri.xcodeproj` in Xcode and build the `TeslaSiri` app target. For agent-driven work, use the Xcode MCP tools first:

- `XcodeGlob` to inspect project files.
- `XcodeRead` to read source files.
- `XcodeGrep` to search project content.
- `XcodeUpdate` to edit project files when replacing existing content.
- `XcodeRefreshCodeIssuesInFile` for fast Swift diagnostics when available.
- `BuildProject` for full project validation.

Use CLI tools only for repo-level tasks that are not represented in the Xcode project structure, such as `git status`, root documentation, `.gitignore`, and `.gitattributes`.

## Coding Standards

- Follow SwiftUI patterns with clear view state and data flow.
- Prefer Swift concurrency with `async` and `await`.
- Avoid adding Combine unless there is a specific need.
- Use `@State private var` for SwiftUI state and `let` for constants.
- Keep type names PascalCase and properties/methods camelCase.
- Avoid force unwrapping.
- Keep comments focused on non-obvious logic.

## Validation

Before handing off source changes, run Xcode diagnostics or a full Xcode build. Prefer `BuildProject` over ad hoc CLI builds so validation matches the active Xcode project.

## Git

This repo intentionally ignores local Xcode user state, build products, DerivedData, SwiftPM working folders, and common secret files. Do not commit Tessie access tokens, exported raw vehicle data, private keys, provisioning profiles, or local Xcode `xcuserdata`.
