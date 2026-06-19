# Claude Instructions

This repository is an Xcode-based SwiftUI iOS app. Claude and all other agents must use Xcode MCP tools before CLI tools for project work.

The AGENTS.md is the primary source of instructions for all AI coding agents working in this repository. While the CLAUDE.md is the primary source for Claude, the AGENTS.md may be more up to date. Make sure you check it and update the CLAUDE.md with anything it is missing, and follow that.

## Highest Priority: Use Xcode MCP First

For anything inside the Xcode project, use:

- `XcodeGlob` for project file discovery.
- `XcodeRead` for reading source and plist files.
- `XcodeGrep` for searching project content.
- `XcodeUpdate` for literal replacements in existing project files.
- `XcodeRefreshCodeIssuesInFile` for quick Swift diagnostics when available.
- `BuildProject` for builds.

Do not use shell commands as the first choice for Xcode project files. Avoid `ls`, `find`, `grep`, `sed`, `cat`, direct filesystem edits, and raw `xcodebuild` unless the Xcode MCP tools are unavailable or the task is outside the Xcode project.

Allowed CLI uses:

- Git inspection and non-destructive Git setup.
- Root-level documentation and repo metadata files.
- Files not visible through Xcode MCP.
- Explicit user requests for terminal output.

When CLI fallback is necessary for project files, explain the reason.

## Project Summary

TeslaSiri is a SwiftUI iOS app that connects to Tessie for Tesla vehicle data. It includes:

- Tessie access-token setup with Keychain-backed storage.
- Tessie response adapters into app-owned Fleet models.
- Observable Fleet data store.
- Local cache hydration and refresh.
- Vehicle dashboard UI.
- Local `TeslaVehicleKit` RealityKit dependency for configuration-aware vehicle rendering and animation.
- Drive, route, charging, software update, telemetry, and raw export flows.
- Local notification payload handling; Tessie does not expose the old custom webhook-management API.
- FleetKit local Swift package: Siri/Shortcuts/App Intents, ExtensionKit host, shared keychain token bridge (see `AGENTS.md` → FleetKit and App Intents).

## Key Files

- `TeslaSiri/ContentView.swift`: `@main` App entry point only; wires shared services into `AppRootView`.
- `TeslaSiri/UI/AppRootView.swift`: TabView shell (`AppTab` enum + `AppRootView`) and shared auth/diagnostics state.
- `TeslaSiri/UI/Dashboard/`: User-facing dashboard cards (vehicle picker, status, software, active drive, charging, cached data, sign-in banner).
- `TeslaSiri/UI/Dashboard/TeslaVehicleRenderer.swift`: Maps Tessie model, paint, interior, trim, and wheel data into the local `TeslaVehicleKit` package at `/Users/mweinbach/Documents/Codex/2026-06-18/look`.
- `TeslaSiri/UI/Drives/`: Drive demo: drive picker, route map, session summary, scrubber, metric tiles.
- `TeslaSiri/UI/Diagnostics/`: Tessie diagnostics, normalized data, Spotlight debugging, account.
- `TeslaSiri/UI/Shared/`: Reusable building blocks (`CardContainer`, `StatusBadge`, formatters, geocoder actor, `DiagnosticMonospacedValue`).
- `TeslaSiri/FleetAPI/FleetAPIClient.swift`: Tessie API client and normalized compatibility surface.
- `TeslaSiri/FleetAPI/TessieAPIModels.swift`: Tessie DTO adapters.
- `TeslaSiri/FleetAPI/FleetAPIModels.swift`: Data models.
- `TeslaSiri/FleetAPI/FleetDataStore.swift`: Observable app data state.
- `TeslaSiri/FleetAPI/FleetDataCache.swift`: Cache layer.
- `TeslaSiri/FleetAPI/FleetAccessTokenKeychain.swift`: Keychain token storage.
- `TeslaSiri/FleetAPI/FleetDeviceIdentity.swift`: Device identity.
- `TeslaSiri/FleetAPI/FleetNotifications.swift`: Local notifications and legacy webhook payload decoding.
- `TeslaSiri/FleetAPI/TessieAccessTokenStore.swift`: Tessie token persistence and extension mirroring.
- `TeslaSiri/Info.plist`: App metadata and background task settings.
- `FleetKit/Sources/FleetKit/`: App Intents, entities, `FleetIntentClient`, snippet views (`FleetKitPackage`).
- `FleetKit/Sources/FleetKit/FleetKitLog.swift`: OSLog loggers (subsystem `com.maxweinbach.TeslaSiri`) + `FleetIntentLog` perform tracker; see `AGENTS.md` → Logging (FleetKitLog) for conventions and the device-debug `ENABLE_DEBUG_DYLIB` note.
- `TeslaSiri/AppIntents/`: `FleetTokenBridge`, `TeslaSiriShortcuts`, `BatteryReminderManager`.
- `TeslaSiriAppIntents/`: thin App Intents extension re-exporting `FleetKitPackage`.

## Worktree Safety

Other agents may be editing files at the same time. Always inspect current status before making changes. Do not revert, overwrite, or clean up changes you did not make.

If source files are dirty from another task, leave them alone unless the user asked you to work on those exact files.

## Style

- Follow existing SwiftUI structure and naming.
- Prefer Swift concurrency over Combine.
- Avoid force unwraps.
- Keep UI changes scoped and consistent with the existing dashboard.
- Keep documentation precise and current with the code.
- Do not add unrelated abstractions or broad refactors.

## Validation

Use Xcode validation tools. For Swift changes, run fast diagnostics first, then `BuildProject` when practical. For docs-only changes, verify file content and Git status.
