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

## 服务器端中继（可选）

`server/` 提供与 v1 协议兼容的 WebSocket Relay，可部署到有公网 IP 的服务器，
替代「局域网里一台设备当 Relay」的模式。房间状态在内存中，无数据库；公网部署必须用
`wss://`（由 Caddy/Nginx 终止 TLS）。

```bash
docker compose up -d --build      # 默认 8765
curl -s http://127.0.0.1:8765/healthz
```

客户端把「服务器地址」填成 `wss://你的域名`、`你的域名` 或 `IP:8765` 即可；
不填端口时 `ws` 默认 8765、`wss` 默认 443。详见 [`server/README.md`](server/README.md)。

## 客户端使用（v0.2.0）

- **我的昵称**：设置页可填 1–16 个字符，支持中文，保存在本地；未设置时显示「访客」。
  改名通过协议 `ping` 的可选 `displayName` 发送，不需要等下一次心率上报。
- **房间号**：房间页顶部大字显示，点击房间号或复制图标即可复制。未加入房间时显示空态。
- **成员列表**：仅显示昵称与心率；离线成员灰显为「-- BPM / 已离线」，不展示过期心率。
- **服务器地址**：支持域名、IP、`host:port`、`ws://`、`wss://`；非法输入会提示具体原因。
- **默认服务器**：构建时可覆盖，不需要改代码：

```bash
flutter build apk --release --split-per-abi \
  --dart-define=DEFAULT_SERVER=heart.example.com
```

`DEFAULT_SERVER` 的代码默认值留空；用户手动填写的地址优先于该默认值。

## Local authoring/build restriction

This repository was written without running Flutter, installing an SDK, or
building. No claim is made that analysis/tests/build already passed. CI owns
validation and artifacts.

## CI and Android APK

The included `.github/workflows/flutter-ci.yml` runs on a user-selected GitHub
repository. It uses a hosted Flutter stable toolchain, then:

1. `flutter pub get`, format check, `flutter analyze`, `flutter test`.
2. Runs `tool/ci_prepare_android.sh` to merge missing Gradle wrapper/resources
   from the CI Flutter SDK without overwriting custom Kotlin/manifests.
3. Builds `--release --split-per-abi` APKs. On a `v*` tag, the release job
   publishes them directly as Release assets, so no zip extraction is needed.

Download the `arm64-v8a` asset for most modern phones, allow installation from
the chosen source, and install it. Release builds currently use debug signing
for sideload testing and are not store-ready; Play release requires a separate
securely managed signing pipeline. No repository secrets are embedded.

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
- `DEFAULT_SERVER` (optional): build-time default hostname/IP via
  `--dart-define`; leave empty to require the user to enter a server address.
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
