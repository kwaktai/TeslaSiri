# TeslaSiri

TeslaSiri is a SwiftUI iOS app for viewing Tesla Fleet data through the Fleet backend at `https://fleet.maxweinbach.com`. It signs in with OAuth, stores Fleet tokens in the keychain, loads cached vehicle data, refreshes live Fleet state, and supports local notifications driven by Fleet webhook payloads.

## Project Layout

- `TeslaSiri/ContentView.swift`: SwiftUI app entry point and dashboard UI.
- `TeslaSiri/FleetAPI/FleetAPIClient.swift`: Fleet backend HTTP client and API envelope handling.
- `TeslaSiri/FleetAPI/FleetAPIModels.swift`: Codable Fleet API model types.
- `TeslaSiri/FleetAPI/FleetDataStore.swift`: Main observable data store for bootstrap, sync, selected vehicle data, software actions, drives, routes, charging, and telemetry.
- `TeslaSiri/FleetAPI/FleetDataCache.swift`: Local Fleet data cache support.
- `TeslaSiri/FleetAPI/FleetAccessTokenKeychain.swift`: Keychain-backed OAuth token persistence.
- `TeslaSiri/FleetAPI/FleetDeviceIdentity.swift`: Device identity used for webhook registration.
- `TeslaSiri/FleetAPI/FleetNotifications.swift`: Notification payload decoding, local notification scheduling, and webhook state.
- `TeslaSiri/FleetAPI/FleetOAuth.swift`: OAuth authorization code flow, PKCE, token exchange, refresh, and token inspection.
- `TeslaSiri/Info.plist`: App metadata, including the `teslasiri://oauth/callback` URL scheme.

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

This repo intentionally ignores local Xcode user state, build products, DerivedData, SwiftPM working folders, and common secret files. Do not commit OAuth tokens, exported raw vehicle data, private keys, provisioning profiles, or local Xcode `xcuserdata`.
