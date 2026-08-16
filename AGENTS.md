# AGENTS.md

Native SwiftUI iOS app (iPhone + iPad, iOS 16.0+) that manages Clash/OpenClash/sing-box controllers via the Clash RESTful API and LuCI JSON-RPC. UI strings and commit messages are (Simplified) Chinese.

## Build & verify

- Single Xcode project with scheme `Clash Dash`. Build: `xcodebuild -scheme "Clash Dash" -destination 'platform=iOS Simulator,name=iPhone 16' build` (or any simulator).
- The scheme's `test` action exists, but both test targets are stubs (Swift Testing `@Test` placeholders). **Verify by building, not testing.** No lint/typecheck tooling exists.
- Deployment targets: app, `Shared`, and widget = iOS 16.0; tests = 18.0. Don't use iOS 17+/18-only APIs in app code without availability guards.
- App version lives in `project.pbxproj` (`MARKETING_VERSION` = 1.4.0, `CURRENT_PROJECT_VERSION` = 4). Release flow: bump both, push tag `v*` → `.github/workflows/build-ipa.yml` builds an unsigned IPA and creates a GitHub Release.

## Target layout (5 targets)

- `Clash Dash` — app. Entry: `Clash Dash/Clash_DashApp.swift` → `AdaptiveContentView` (sidebar vs. navigation layout).
- `WidgetExtensionExtension` — widget (source folder is `WidgetExtension/`).
- `Shared` — framework sharing server status with the widget via app-group `UserDefaults` (`Shared/SharedModels.swift`).
- `Clash DashTests`, `Clash DashUITests` — placeholders.

## Gotchas

- The project uses Xcode 16 filesystem-synchronized groups: **new files under `Clash Dash/`, `Shared/`, `WidgetExtension/`, and the test folders are auto-added to targets — never hand-edit `project.pbxproj` to add files.** But files in `Clash Dash/` also compile into `Shared` and the widget unless excluded via membership exceptions (`Models/ClashServer.swift`, `Models/NetworkError.swift`, `Models/NetworkMonitor.swift` are excluded from the widget; the first two from `Shared`). Check these exceptions before adding files that touch shared folders.
- `Yams` (SPM) is linked only to the app target — YAML parsing (`Utils/YAMLValidator.swift`) is app-only; `Shared`/widget cannot use it.
- App `Info.plist` is `Clash-Dash-Info.plist` at the repo root (ATS `NSAllowsArbitraryLoads`, `ClashDash` URL scheme, CloudKit keys). Root `Info.plist` is legacy/unused — don't edit it.
- Secrets live in the Keychain (`Utils/KeychainManager.swift`); the widget reads them from app-group `UserDefaults` with keys prefixed `group.ym.si.clashdash_<address>_secret`. Keep this split when changing auth storage.
- iCloud sync (`Utils/CloudKitManager.swift`) uses container `iCloud.ym.si.clashdash`; entitlements are required, so the app won't launch on a simulator without an iCloud-enabled team configured.
- App requests local-network permission at launch (`LocalNetworkAuthorization`); `Debug/` scripts (`get_openclash_status.sh`, `test_clash_controller.sh`) are user-facing diagnostics linked from `TROUBLESHOOTING.md` — keep them working when touching LuCI/OpenClash auth.
- Controller types: `clashController` (Clash RESTful API + WebSocket), `openWRT` (LuCI JSON-RPC, packages `openclash`/`mihomo_tproxy`), `surge` (`Models/ClashServer.swift`).
