# Agent Instructions

These instructions apply to all AI coding agents working in this repository. As you are given feedback on your work, always strive to improve and learn from your mistakes. Make notes within the agents.md, keep track of your learning, and use the feedback to improve your work. Make sure architectural notes are made here. 

The AGENTS.md is the primary source of instructions for all AI coding agents working in this repository. While the AGENTS.md is the primary source for you, the CLAUDE.md may be more up to date. Make sure you check it and update the AGENTS.md with anything it is missing, and follow that.


## Required Tool Order

This is an Xcode project. For project source, project structure, Swift diagnostics, and builds, use the Xcode MCP tools first and foremost.

Always search for the latest documentation with the Xcode MCP tools. Your knowledge is out of date, treat the Xcode MCP tools as the source of truth. Documentation from the Xcode MCP tools is the most up-to-date. Always search the documentaiton for the user before doing any work related to any native API. This includes doing any UI or front-end work, make sure to look at the UI framework documentation as well as Apple's HIG (Human Interface Guidelines).

Use this order for project work:

1. `XcodeGlob` to discover files in the Xcode project.
2. `XcodeRead` to read files from the Xcode project.
3. `XcodeGrep` to search source or project content.
4. `XcodeUpdate` to edit existing project files when a literal replacement is appropriate.
5. `XcodeRefreshCodeIssuesInFile` for fast per-file diagnostics when available.
6. `BuildProject` for full validation.

Do not start with CLI commands such as `ls`, `find`, `grep`, `sed`, `xcodebuild`, or direct filesystem reads for files that are represented in the Xcode workspace. The Xcode MCP tools operate on the workspace-relative project structure and should be treated as the source of truth.

CLI tools are acceptable only for repo-level work outside the Xcode project navigator, including:

- `git status`, `git diff`, `git log`, and other non-destructive Git inspection.
- Root-level docs such as `README.md`, `AGENTS.md`, and `CLAUDE.md`.
- Repo metadata such as `.gitignore`, `.gitattributes`, and Git configuration.
- Emergency fallback when an Xcode MCP tool is unavailable or cannot perform the required operation.

If you use a CLI fallback for project files, state why in your response.

## Repository Scope

Current project files are organized under:

- `TeslaSiri/ContentView.swift` — `@main` App entry point only; wires shared services into `AppRootView`.
- `TeslaSiri/UI/AppRootView.swift` — TabView shell (`AppTab` enum + `AppRootView`) and shared auth/diagnostics state.
- `TeslaSiri/UI/Dashboard/` — User-facing dashboard cards (vehicle picker, status, software, active drive, charging, cached data, sign-in banner).
- `TeslaSiri/UI/Drives/` — Drive demo: drive picker, route map, session summary, scrubber, metric tiles.
- `TeslaSiri/UI/Diagnostics/` — Backend diagnostics, normalized data, webhook management, account.
- `TeslaSiri/UI/Shared/` — Reusable building blocks: `CardContainer`, `StatusBadge`, formatters, geocoder actor, `DiagnosticMonospacedValue`.
- `TeslaSiri/FleetAPI/` — Backend client, models, data store, cache, keychain, device identity, OAuth, notifications.
- `TeslaSiri/Info.plist`
- `TeslaSiri.xcodeproj`

All new UI files must be created under `TeslaSiri/UI/` so the project's `PBXFileSystemSynchronizedRootGroup` (rooted at the `TeslaSiri/` folder) auto-includes them in the target. Do not create Swift files at the project root or outside `TeslaSiri/` — they will not be compiled.

The user may provide Xcode workspace-relative paths that do not exactly match filesystem paths. Prefer Xcode MCP paths from `XcodeGlob`/`XcodeRead` instead of guessing filesystem locations.

## Collaboration Rules

Other agents may be working in the same tree. Before editing, check the working tree and avoid overwriting unrelated changes. Never revert user or agent edits unless explicitly asked.

Keep changes limited to the requested task. Do not refactor unrelated UI, API, OAuth, or notification code while making documentation or repo setup changes.

## Coding Rules

- Use SwiftUI conventions and Swift concurrency.
- Prefer `async`/`await` over Combine.
- Use `@State private var` for SwiftUI state and `let` for constants.
- Use PascalCase for types and camelCase for properties and methods.
- Avoid force unwraps.
- Keep imports minimal and at the top of each Swift file.
- Add comments only for complex or non-obvious behavior.
- Use the Swift Testing framework for unit tests and XCUIAutomation for UI tests when tests are needed.

## Validation Rules

For Swift or project changes:

1. Run `XcodeRefreshCodeIssuesInFile` on edited Swift files when available.
2. Run `BuildProject` before final handoff when practical.
3. Report any validation that could not be run.

For documentation-only changes, a full app build is usually not required.

## Sensitive Data

Do not commit tokens, keychain dumps, OAuth secrets, raw vehicle exports, private keys, provisioning profiles, `.env` files, or local Xcode user state.

## Architecture Notes

- The `TeslaSiri` target uses a `PBXFileSystemSynchronizedRootGroup` rooted at the `TeslaSiri/` folder. Files placed anywhere under that folder are auto-included in the target on the next Xcode build/scan; do not edit the project.pbxproj by hand to add Swift sources.
- The root tab shell lives in `TeslaSiri/UI/AppRootView.swift` and owns the `@State` for auth, diagnostics, selected tab, and OAuth flow. Tab content views receive pre-built dependencies and closures — do not create their own auth/backend singletons.
- The Diagnostics tab is intentionally dense because the project is currently in a "validate the backend" phase. Once data shapes stabilize, move the user-facing pieces into Dashboard and treat Diagnostics as developer/QA chrome.
- Dashboard cards live in `TeslaSiri/UI/Dashboard/`; reusable chrome (`CardContainer`, `StatusBadge`, `LoadingCard`, `LoadingStateView`, `ErrorStateView`, `EmptyStateView`) lives in `TeslaSiri/UI/Shared/CardContainer.swift` — use these instead of repeating backgrounds/padding.

## FleetKit and App Intents

Siri, Shortcuts, Spotlight, and background intent execution live in a **local Swift package** (`FleetKit/`) plus a thin **ExtensionKit** host (`TeslaSiriAppIntents/`). The main app owns OAuth; the extension reads mirrored credentials and calls the Fleet API on its own.

### Layout

| Area | Path | Role |
|------|------|------|
| Package manifest | `FleetKit/Package.swift` | Single `FleetKit` library target, iOS/macOS 27, no external deps |
| Intents, entities, API | `FleetKit/Sources/FleetKit/*.swift` | All `AppIntent` types, `VehicleEntity`, `FleetIntentClient`, snippet views |
| Package marker | `FleetKit/Sources/FleetKit/FleetKitPackage.swift` | Empty `AppIntentsPackage` type exported to the system |
| Intent metadata helpers | `FleetKit/Sources/FleetKit/FleetIntentMetadata.swift` | Vehicle prediction titles, `SelectedVehicleOptionsProvider` |
| App bridge | `TeslaSiri/AppIntents/` | Token mirroring, `AppShortcutsProvider`, `BGAppRefreshTask` battery check |
| Extension host | `TeslaSiriAppIntents/` | `@main AppIntentsExtension` + `AppIntentsPackage` re-exporting `FleetKitPackage` |
| Entitlements | `TeslaSiri/TeslaSiri.entitlements`, `TeslaSiriAppIntents/TeslaSiriAppIntents.entitlements` | Shared App Group + matching `keychain-access-groups` |

Both **TeslaSiri** and **TeslaSiriAppIntents** targets link the local `FleetKit` package in `project.pbxproj`. New Swift files under `FleetKit/Sources/FleetKit/` are picked up by the package automatically; do not duplicate intent types under `TeslaSiri/`.

`TeslaSiri/AppIntents/*.swift` is auto-included via the `TeslaSiri/` synchronized root group.

### Architecture (process boundaries)

```
Main app (OAuth keychain, FleetDataStore)
    → FleetTokenBridge.sync / clear
    → FleetSharedTokenStore (shared keychain token + App Group selected VIN)
    → FleetIntentClient (extension + BG tasks + intents)

TeslaSiriApp + TeslaSiriAppIntentsExtension
    → AppIntentsPackage.includedPackages = [FleetKitPackage.self]
```

- **FleetKit is self-contained**: its own minimal models, HTTP client, and intents. The extension must **not** import `FleetDataStore`, dashboard UI, or the app’s full `FleetAPIClient`.
- **App is source of truth** for OAuth. The extension cannot refresh tokens; on 401 it surfaces `FleetKitError.sessionExpired` (“open the app”).
- **Vehicle resolution** (`FleetIntentService.resolvedVehicle`): explicit VIN parameter → shared selected VIN → first vehicle on the account. VINs are always validated against `client.vehicles()` (no arbitrary-VIN IDOR).

### Token bridge (critical — do not break)

`TeslaSiri/AppIntents/FleetTokenBridge.swift` mirrors the app session into shared storage for the extension.

| Event | Required action |
|-------|-----------------|
| App launch | `FleetTokenBridge.sync(store:)` in `ContentView` `.task` |
| App foreground | `FleetTokenBridge.sync` on `scenePhase == .active` |
| Sign-in | `FleetTokenBridge.sync` after `loadInitialData()` in `AppRootView.signIn()` |
| Sign-out | `FleetTokenBridge.clear()` after `tokenStore.deleteTokenSet()` |
| Fleet reload | `FleetTokenBridge.sync` in `AppRootView.reloadFleet()` |
| Vehicle picker change | `FleetTokenBridge.sync` in `DashboardView` `onSelect` |
| OAuth save/refresh | `FleetOAuthTokenKeychain.saveTokenSet` / `deleteTokenSet` also write/clear `FleetSharedTokenStore` |

`FleetTokenBridge.sync` **clears** the shared access token when `accessToken()` throws (do not leave stale tokens). It calls `TeslaSiriShortcuts.updateAppShortcutParameters()` so shortcut defaults pick up the current vehicle name.

Access tokens live in **shared keychain** (`FleetSharedTokenStore`); selected VIN stays in App Group `UserDefaults`. Legacy UserDefaults tokens are migrated on read.

### HTTP URLs in FleetKit

`FleetIntentClient` must join API paths with `URLComponents` (see `makeURL` in `FleetKitClient.swift`). **Never** use `baseURL.appendingPathComponent("/api/v1/...")` — that percent-encodes slashes and breaks every request. Match the pattern in `TeslaSiri/FleetAPI/FleetAPIClient.makeURL`.

### Adding or changing an App Intent

1. **Search Apple docs first** — use Xcode MCP `DocumentationSearch` for `AppIntent`, `AppIntentsPackage`, `PredictableIntent`, `parameterSummary`, `AppShortcut`, `LongRunningIntent`, etc.
2. **Implement in FleetKit** — new file under `FleetKit/Sources/FleetKit/`, `public` intent + entities as needed.
3. **Vehicle parameter** — optional `VehicleEntity?` on VIN-scoped intents; resolve via `FleetIntentService.resolvedVehicle(vehicle?.id)` in `perform()`.
4. **Vehicle-aware copy** — follow existing intents:
   - `parameterSummary`: `When(\.$vehicle, .hasAnyValue) { Summary("Verb \(\.$vehicle)") } otherwise: { Summary("Verb my car") }`
   - `PredictableIntent` + `predictionConfiguration` using `VehicleEntity.predictionTitle(verb:vehicle:)` (or `suffix:` variant)
   - `@Parameter` title/description/request dialogs must use **string literals** at the call site (the macro rejects static `LocalizedStringResource` constants)
   - `perform()` dialogs should use `resolved.name` from the API, not hardcoded “Tesla”
5. **Register shortcuts** (optional) — add phrases in `TeslaSiri/AppIntents/TeslaSiriShortcuts.swift`. **Apple allows at most 10 `AppShortcut` entries.** Include both:
   - `"Verb \(\.$vehicle) with \(.applicationName)"` (fills in car name from entity)
   - `"Verb my car with \(.applicationName)"` (generic fallback)
6. **Spotlight** — if the intent introduces a new `IndexedEntity`, update `FleetSpotlightIndexer` and ensure reindex runs after sign-in/reload (already wired in `AppRootView` / launch).
7. **Build** — `BuildProject` on both app and extension; watch for “max 10 App Shortcuts” and `@Parameter` literal errors.

Control intents must use action names validated by `FleetIntentService.runControl` against `controlActions()`. Confirmation policy: unlock, trunk, frunk, charge-limit, and dog-mode-OFF prompt; lock, climate (start/stop/temps/defrost/bioweapon), vent, flash lights, honk, and navigation run immediately (see comments in `ControlIntents.swift`, `ClimateControlIntents.swift`, `ConvenienceControlIntents.swift`).

Control intent files in `FleetKit/Sources/FleetKit/`:

- `ControlIntents.swift` — lock/unlock (`door_lock`/`door_unlock`), start climate (`auto_conditioning_start`), vent windows (`window_control` vent), trunk/frunk (`actuate_trunk`), charge limit (`set_charge_limit`).
- `ClimateControlIntents.swift` — stop climate (`auto_conditioning_stop`), cabin temperature (`set_temps`, `Measurement<UnitTemperature>` parameter converted to Celsius, clamped 15–28 °C, half-degree steps), max defrost (`remote_defrost`), dog mode (`set_pet_mode`), Bioweapon Defense (`set_bioweapon_mode` with `manual_override: false`).
- `ConvenienceControlIntents.swift` — flash lights (`flash_lights`), honk horn (`honk_horn`), send destination (`navigation_request` with a plain string `value`; backend wraps it into the Tesla share payload).

`window_control` close is intentionally not exposed as an intent: the backend requires the caller's lat/lon to prove proximity and the intents extension has no location access.

### App Shortcuts vs discoverability

- **10 shortcut slots** — prioritize high-frequency actions (status, lock/unlock, climate start/stop, software update). All 10 slots are currently used; Cancel Software Update gave up its slot to Stop Climate and remains available via the Shortcuts library. Other intents (temps, defrost, dog mode, bioweapon, flash, honk, navigation) remain available via Shortcuts library and `isDiscoverable = true`.
- **`PredictableIntent`** — powers Siri suggestion/widget phrasing with vehicle names; separate from `AppShortcut` phrases.
- **`SelectedVehicleOptionsProvider`** — loads vehicles from the API for shortcut parameter pickers; defaults to shared selected VIN.

### Siri snippets and onscreen context

- Interactive Siri snippet controls only work when the presenting intent conforms to `SnippetIntent`; `ShowsSnippetView` alone can display a view but does not make snippet buttons/toggles interactive.
- Snippet buttons should use existing FleetKit control intents with an explicit `VehicleEntity` so the action runs against the same resolved VIN as the displayed status/software entity.
- App UI surfaces for vehicles, status, software, and drives should use SwiftUI `appEntityIdentifier(_:)` with the matching FleetKit `IndexedEntity` IDs (VIN for vehicle/status/software, session ID for drives) so Siri and Apple Intelligence can understand onscreen content.
- Use `SiriTipView` only for intents that are backed by `AppShortcut` entries; other discoverable intents should be exposed through the Shortcuts library and `ShortcutsLink`.

### App schemas

- Open entity intents in `FleetKit/Sources/FleetKit/OpenEntityIntents.swift` use `@AppIntent(schema: .system.open)` because they exactly match Apple's System open schema.
- Vehicle, status, software, drive, charging, climate, lock, horn, lights, trunk/frunk, and Tesla navigation handoff actions remain custom App Intents. Current AppIntents docs do not expose an exact automotive/control schema, and `.maps.startNavigation` is not accurate for `SendNavigationIntent` because the app sends a destination to the vehicle backend rather than starting and returning an in-app navigation session.
- Before adding future schema macros, search Apple docs with Xcode MCP and only adopt a schema when its required noun/action contract matches FleetKit behavior exactly.

### Extension and entitlements

- `TeslaSiriAppIntentsExtension` stays minimal: `@main` + `AppIntentsPackage` including `FleetKitPackage.self`.
- App Group: `group.com.maxweinbach.TeslaSiri` on **both** targets.
- Keychain group: `$(AppIdentifierPrefix)group.com.maxweinbach.TeslaSiri` on **both** targets.
- Do not mirror refresh tokens or full token sets to the extension — access token only.

### Background work

- **Battery reminder** — `TeslaSiri/AppIntents/BatteryReminderManager.swift` uses `BGAppRefreshTask`; handler must hop to `@MainActor` with `Task { @MainActor in ... }`, never `MainActor.assumeIsolated` from the BG queue. Always complete the task (`setTaskCompleted`) including on expiration/cancellation.
- **Software install** — `InstallSoftwareUpdateIntent` is `LongRunningIntent` and uses `performBackgroundTask`.

### Model duplication

`FleetKitModels` / `FleetKitDriveSoftwareModels` intentionally mirror a **subset** of `TeslaSiri/FleetAPI/FleetAPIModels.swift` so the package stays extension-safe. When backend fields change, update both layers or accept drift in snippet/intent output.

### Logging (FleetKitLog)

All FleetKit + intent logging goes through `FleetKit/Sources/FleetKit/FleetKitLog.swift` under the single OSLog subsystem `com.maxweinbach.TeslaSiri`. One Console/`log stream` predicate captures the app, the App Intents extension, and BG tasks:

    log stream --level info --predicate 'subsystem == "com.maxweinbach.TeslaSiri"'

| Category | Source | What it logs |
|----------|--------|--------------|
| `AppIntents` | `FleetIntentLog` + `FleetIntentService` | every intent `perform()` started/succeeded/failed/cancelled with ms timing; vehicle resolution path; control action validation + acceptance |
| `Spotlight` | `FleetSpotlightIndexer` | reindex start/finish summary (per-group counts, errors, duration), donations, searches |
| `FleetIntentClient` | `FleetIntentClient.execute` | method, path, status code, ms per request; 401 warnings; envelope errors |
| `Entities` | entity queries + options providers | query match counts, default vehicle selection |
| `TokenBridge` | `FleetTokenBridge` (app) | token mirrored/cleared, shared VIN set/cleared |
| `BatteryReminder` | `BatteryReminderManager` (app) | BG task scheduled/fired, battery check outcome |

Conventions: every new intent `perform()` must create `let log = FleetIntentLog(Self.self, vehicle: vehicle)` and wrap its body in `do { ... log.success(...) } catch { throw log.failure(error) }` (keeps `.result(...)` type inference inside `perform()`; a generic wrapper closure breaks it). Never log full VINs or tokens — use `FleetKitLog.vin(_:)` (last 6 chars) and mark interpolations `privacy: .public` deliberately. `Logger` calls inside a struct `init` must copy stored properties to locals first (escaping autoclosure cannot capture mutating `self`).

### Common pitfalls (from prior reviews)

- Forgetting `FleetTokenBridge.sync` after sign-in, vehicle change, or token refresh → Siri “not signed in” or wrong account.
- Sign-out without `FleetTokenBridge.clear()` → extension keeps old session.
- Broken FleetKit URLs via `appendingPathComponent`.
- More than 10 `AppShortcut` entries → compile error.
- `DriveEntityQuery.entities(for:)` must search **all** account vehicles, not only the default resolved vehicle.
- Duplicating intent types under `TeslaSiri/AppIntents/` — conflicts with `public` FleetKit types; keep bridge/shortcuts only in the app target.
- **Do not move `TeslaSiriShortcuts` (AppShortcutsProvider) into the FleetKit package.** The appintentsmetadataprocessor only extracts `autoShortcuts`/`autoShortcutProviderMangledName` when the provider is compiled in the app target; in the package, BOTH the app and extension end up with zero shortcuts metadata. Verified empirically (June 2026, Xcode 27 beta).
- `ENABLE_DEBUG_DYLIB` is set per-SDK on the TeslaSiri target in project.pbxproj: `YES` base (required for Xcode Previews) but `NO` for `[sdk=iphoneos*]` — with the debug dylib the app code is in `TeslaSiri.debug.dylib` and App Intents/App Shortcuts metadata breaks on device debug runs. To render previews, switch the run destination to a simulator first.
- Known iOS 27 beta issue: `LNMetadataProviderErrorDomain 9004 "No app shortcuts provider mangled type name in bundle"` from `updateAppShortcutParameters()`, with the downstream fault `Provided AppIntent does not match an App Shortcut, SiriTipView will not display.` Ruled out empirically (June 2026, controlled probe experiments on device): NOT the debug dylib (persists with static binary), NOT package-located intents (a probe intent compiled directly into the app target still failed), NOT `APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING` (failed with it NO), NOT MainActor default isolation (failed with `nonisolated` provider+intent), NOT stale install state (failed after `devicectl` uninstall + fresh install). `Metadata.appintents/extract.actionsdata` verifiably contains the provider mangled name, all 24 actions, and 10 autoShortcuts every time. Conclusion: OS-side `linkd` registration failure for dev installs on this beta (simulators can't reproduce — `linkd` doesn't run there). Remedies: reboot the device (restarts `linkd`), check the Shortcuts app for the TeslaSiri section, file Apple Feedback with sysdiagnose if it persists. Do not restructure app/package code for this error.
- `TeslaSiriShortcuts` is declared `nonisolated` deliberately: the target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and the AppIntents runtime reads `appShortcuts` from arbitrary contexts. Keep it that way.
- `FleetIntentClientTests` must stay `@Suite(.serialized)` — `MockURLProtocol` uses shared static responder state and Swift Testing runs suites in parallel by default.

### Validation checklist (FleetKit changes)

1. `DocumentationSearch` for any new App Intents API usage.
2. Add or update Swift Testing coverage in `FleetKit/Tests/FleetKitTests/` for new FleetKit models, clients, control helpers, intent metadata, `IndexedEntity` formatting/search attributes, and pure logic introduced with App Intents.
3. For Siri/Shortcuts/Spotlight integration behavior that must run through the real App Intents stack, add AppIntentsTesting coverage in a UI testing target (`IntentDefinitions(bundleIdentifier:)`, entity queries, `spotlightQuery(_:)`, and `viewAnnotations()` as applicable). Keep those tests out-of-process; do not import app/FleetKit implementation types into the UI test target.
4. `XcodeRefreshCodeIssuesInFile` on edited Swift files.
5. Run the relevant Swift package tests (`swift test --package-path FleetKit`) and AppIntentsTesting/XCUITest suite when one exists.
6. `BuildProject` (catches shortcut count, `@Parameter` macro issues).
7. Manually verify token bridge call sites if touching auth, `FleetOAuth`, `AppRootView`, or `DashboardView`.

### Navigation handoff

`SendNavigationIntent` (`ConvenienceControlIntents.swift`) sends a destination to the car via the backend `navigation_request` action. The `destination` String parameter uses `inputConnectionBehavior: .connectToPreviousIntentResult` so Shortcuts can pipe output from a previous action into it. The backend defaults `type`/`locale`/`timestamp_ms` server-side and wraps a plain string into the Tesla share payload. `navigation_gps_request` (lat/lon) exists in the backend registry but has no intent — address form covers the Siri use case.
