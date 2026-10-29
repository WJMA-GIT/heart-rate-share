# 共享心率 (Heart Rate Share) — MVP skeleton

Flutter single-repository skeleton for standard BLE HRS collection and a local
WebSocket room relay. Application ID: `com.wjmagit.heartrateshare`.

## Implemented

- HRS 0x180D / 0x2A37 scan-connect-notify path for Android using
  `flutter_blue_plus: 2.3.13`; parser supports 8/16-bit BPM, sensor-contact bits,
  Energy Expended skipping, and multiple RR values (1/1024 s → ms).
- Explicit C++/WinRT and Swift channel contracts/TODO stubs for Windows/iOS.
- Relay member store, 1 Hz latest-sample reports, 1 s snapshots, deltas,
  sequence checks, 5 s offline, 2 min expiry, 20-member limit.
- Three pages (heart, room, settings), opt-in Debug panel, per-session local
  logs, share/export, room short-code field and manual address fallback.
- Unit tests and a real loopback WebSocket integration test.

## Not implemented (do not assume it works)

- Windows/iOS native BLE central implementations; both explicitly throw
  `UnsupportedError` rather than simulate a connection.
- Actual mDNS registration/discovery. `nsd: 4.0.0` is pinned, but its integration
  is deferred until API compatibility is checked by CI; manual address works.
- Android foreground service and OEM-specific background recovery.
- WSS/TLS, certificate validation, room authentication and room epoch recovery.
  The current `ws://` relay is development-only and has no join authentication.
- Full Windows/iOS platform runners, iOS signing, release signing and stores.

## Local authoring/build restriction

This repository was written without running Flutter, installing an SDK, or
building. No claim is made that analysis/tests/build already passed. CI owns
validation and artifacts.

## CI and debug APK

The included `.github/workflows/flutter-ci.yml` runs on a user-selected GitHub
repository. It uses a hosted Flutter stable toolchain, then:

1. `flutter pub get`, format check, `flutter analyze`, `flutter test`.
2. Runs `tool/ci_prepare_android.sh` to merge missing Gradle wrapper/resources
   from the CI Flutter SDK without overwriting custom Kotlin/manifests.
3. Builds `app-debug.apk` and uploads artifact `heartrate-debug-apk`.

On GitHub: **Actions → flutter-ci → successful run → Artifacts**. Unzip the
artifact, copy `app-debug.apk` to an Android device, allow installation from the
chosen source, and install it. Debug signing is development-only; Play release
requires a separate securely managed signing pipeline. No repository secrets
are embedded in this project.

Windows/iOS CI jobs are intentionally not advertised until native runners and
BLE implementations exist.

## Debug and logs

Settings → **Debug diagnostics** (off by default). The panel shows adapter
state, scanned names/IDs/RSSI (Android ID is MAC; iOS will be UUID), connection
state, raw HRS bytes, BPM/RR, room members, and recent errors/stacks. The log
export button opens the platform share sheet with a readable text file.

Per-session paths (resolved at runtime, not hard-coded):

- Android: app-specific external files directory, `HeartRateLogs/`; fallback is
  application documents. No broad storage permission is requested.
- iOS: application `Documents/HeartRateLogs/`.
- Windows: application support directory, `HeartRateLogs/`.

Logs use UTC timestamps, level, module, shortened device ID and error code.
Message keys resembling token/secret/password/authorization/API/pairing keys
are redacted. Network envelopes are never logged. Raw HRS bytes are logged only
when Debug is enabled. Users should still inspect exported files before sharing;
logs may contain nicknames, shortened device identifiers and stack traces.

## Placeholders / user-provided inputs

- Application ID (resolved): `com.wjmagit.heartrateshare` — set in
  `lib/core/config/app_config.dart`, Android namespace/applicationId, Kotlin
  package path and channel IDs. Intended iOS bundle ID and Windows identity
  should reuse the same value; note there is no `ios/` Xcode project yet, so
  the bundle ID cannot be set until that project is generated.
- Repository (resolved): https://github.com/WJMA-GIT/heart-rate-share
- `YOUR_CI_SIGNING_SECRET_NAMES`: configure only in your CI secret manager;
  never write signing values into source or logs.
- `YOUR_HRS_DEVICE_MODEL`: test strap must expose standard HRS 0x180D/0x2A37.
- `YOUR_WINDOWS_BLE_ADAPTER`: record model/driver for hardware validation.
- Display name (resolved): 共享心率 — Android label and `AppConfig.displayName`.

There are no API keys, accounts, signing files, tokens, or Git remotes included.

## Dependency/licensing note

`flutter_blue_plus` is pinned to 2.3.13. Its published license states that
for-profit use, including commercial development/evaluation, requires a
commercial license. Review and obtain the appropriate license before commercial
release; do not treat it as an unrestricted BSD dependency.

## Required verification

### CI

- Dependency resolution against the selected Flutter stable version.
- `dart format`, `flutter analyze`, all unit/integration tests.
- Android scaffold merge, manifest merger, debug APK build and artifact download.
- Plugin API compatibility: flutter_blue_plus, web_socket_channel, share_plus,
  package_info_plus, path_provider, and pinned nsd.

### Real devices

- HRS service filtering and names/RSSI; 8/16-bit BPM, contact flags and RR
  against a known strap; removal/reconnection and one-central-only behavior.
- Android 12+ permissions, Android 14+ foreground-service policy, lock screen,
  OEM battery restrictions, log path and system share sheet.
- Windows adapter/driver, native HRS plugin lifecycle, MSIX capability and log
  path; these are blocked on native implementation.
- iOS CoreBluetooth permissions, background/restoration, Bonjour permission,
  log export; these are blocked on native implementation.
- Same-LAN/hotspot discovery and manual join, Relay loss/restart, 20 members at
  1 Hz, offline grey-out after 5 s, privacy and cleartext development warning.

See `docs/protocol.md` for wire fields and thresholds.
