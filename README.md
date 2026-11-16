# Wattie

Wattie는 Tesla 차량을 보고 제어하는 독립 SwiftUI 앱입니다. 차량 대시보드와 Siri, 단축어를 한곳에 모읍니다. Xcode 프로젝트와 앱 타깃 이름은 `TeslaSiri`입니다.

이 포크는 Tessie 대신 소유자의 자체 Tesla 서버를 사용합니다. 기본 주소는 `https://t.kwakhome.com`입니다. API 키는 앱에 넣지 않고, 연결 카드에서 입력한 뒤 Keychain에 저장합니다.

Wattie is an independent SwiftUI app for viewing and controlling Tesla vehicles. This fork talks to a self-hosted Tesla server instead of Tessie. The default server is `https://t.kwakhome.com`. The API key is entered in the app and stored in Keychain. It is never committed.

## Mac에서 빌드하기

Xcode **27.3 이상**이 필요합니다. `@AppIntent(.tool)`와 `@AppEntity(.generable)`는 iOS 27.3 API이고, `FleetKit/Package.swift`의 배포 타깃도 27.3입니다. Xcode 27.2에서는 이 매크로를 컴파일할 수 없습니다. 배포 타깃을 낮추면 Siri AI 도구가 깨지므로 낮추지 마세요.

1. macOS에서 [`TeslaSiri.xcodeproj`](TeslaSiri.xcodeproj/)를 Xcode 27.3 이상으로 엽니다. 스킴은 `TeslaSiri`, 대상은 iOS 27.3 시뮬레이터 또는 기기입니다.
2. 앱 타깃과 `TeslaSiriAppIntents` 확장 모두에서 서명 팀을 본인 Apple Developer 팀으로 바꿉니다. 현재 프로젝트에 들어 있는 팀 ID `6UHAW5UAT4`는 원 저장소 소유자의 팀입니다.
3. 번들 ID를 본인 팀에서 쓸 수 있는 값으로 바꿉니다. 기본값은 앱 `com.maxweinbach.TeslaSiri`, 확장 `com.maxweinbach.TeslaSiri.TeslaSiriAppIntents`입니다. 두 타깃을 함께 바꾸세요.
4. App Group은 두 타깃의 entitlements와 [`FleetKit/Sources/FleetKit/FleetKitConfig.swift`](FleetKit/Sources/FleetKit/FleetKitConfig.swift)의 `appGroupID`가 같아야 합니다. 기본값은 `group.com.maxweinbach.TeslaSiri`입니다. 번들 ID를 바꾸면 App Group과 keychain access group도 같은 접두사로 맞춥니다. Keychain group은 `$(AppIdentifierPrefix)`와 그 App Group을 이어 붙입니다.
5. 앱을 실행합니다. 계정이 없어도 **Diagnostics → Siri & Command Sandbox**에서 **Demo Car**를 켤 수 있습니다.
6. 실제 차량은 Vehicle 탭의 연결 카드에서 서버 URL(비워 두면 `https://t.kwakhome.com`)과 API 키를 입력합니다. 키는 공유 Keychain에 저장되고 Siri 확장이 같은 키를 읽습니다. 키를 소스나 커밋에 넣지 마세요.

잠든 차는 조회만으로 깨우지 않습니다. 명령은 차가 잠들어 거절할 때만 `wake=1`로 깨웁니다. 이 서버에는 주행 기록, 충전 통계, 배터리 건강, 릴리즈 노트가 없습니다. 그 화면은 빈 상태로 두고, Siri는 제공하지 않는다는 말을 합니다.

## Build on a Mac

Xcode 27.3 or later is required. `@AppIntent(.tool)` and `@AppEntity(.generable)` are iOS 27.3 APIs, and `FleetKit` deploys to iOS 27.3. Xcode 27.2 cannot compile those macros. Do not lower the deployment target.

1. Open `TeslaSiri.xcodeproj` in Xcode 27.3 or later. Use the `TeslaSiri` scheme and an iOS 27.3 simulator or device.
2. Set the signing team on both the app target and the `TeslaSiriAppIntents` extension. The checked-in team `6UHAW5UAT4` belongs to the upstream project.
3. Change both bundle IDs if that team cannot use `com.maxweinbach.TeslaSiri` and `com.maxweinbach.TeslaSiri.TeslaSiriAppIntents`.
4. Keep the App Group identical in both entitlements and in `FleetKitConfig.appGroupID` (`group.com.maxweinbach.TeslaSiri`). If you change the bundle ID, change the App Group and the keychain access group (`$(AppIdentifierPrefix)` plus that group) to match.
5. Run the app. Demo Car mode under Diagnostics still works without a server.
6. On the Vehicle tab, enter the server URL and API key. The key is stored in the shared Keychain for the app and the Siri extension. Never commit a key.

Reads do not wake a sleeping car. Commands may wake it. Drive history, charging history, battery health, and release notes are unavailable on this server.

## Project layout

- [`TeslaSiri/`](TeslaSiri/) contains the SwiftUI app and the RealityKit showroom.
- [`TeslaFleetTransport/`](TeslaFleetTransport/) builds requests for the self-hosted server and has Linux-runnable tests.
- [`FleetKit/`](FleetKit/) contains the App Intents and the extension-safe client.
- [`TeslaSiriAppIntents/`](TeslaSiriAppIntents/) hosts the App Intents extension.
- [`TeslaVehicleKit/`](TeslaVehicleKit/) contains the RealityKit loader and vehicle assets.

See [AGENTS.md](AGENTS.md) for development conventions. Keep API keys, raw vehicle exports, and signing files out of commits.

## License

The [MIT License](LICENSE) applies to the project-authored code and documentation. Tesla retains its rights to the vehicle models and related assets in the RealityKit conversions. The [third-party notices](THIRD_PARTY_NOTICES.md) identify the assets and marks excluded from the MIT grant.
