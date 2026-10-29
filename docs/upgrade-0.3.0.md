# 0.3.0 toolchain upgrade record

Date: 2026-10-29. Baseline for rollback is tag `v0.2.0` (`bcb0bd2`).

## Version matrix

| Component | Before | After | Basis |
|---|---|---|---|
| Flutter | 3.27.4 | 3.47.8 | Flutter releases JSON, stable released 2026-10-23 |
| Dart | 3.6.2 | 3.13.7 | Bundled with Flutter 3.47.8 |
| flutter_blue_plus | 2.3.13 | 2.3.14 | pub.dev latest compatible |
| shared_preferences | 2.3.5 | 2.5.6 | pub.dev latest compatible |
| share_plus | 10.1.4 | 13.3.1 | pub.dev latest |
| package_info_plus | 8.1.3 | 10.2.2 | pub.dev latest |
| path_provider | 2.1.5 | 2.1.6 | pub.dev latest |
| web_socket_channel | 3.0.1 | 3.0.3 | pub.dev latest |
| nsd | 4.0.0 | 5.0.1 | pub.dev latest |
| characters | 1.3.0 | 1.4.1 | pub.dev latest |
| flutter_lints | 5.0.0 | 6.0.0 | pub.dev latest |
| Gradle wrapper | 8.3 | 9.3.1 | Flutter 3.47.8 Android template |
| Android Gradle Plugin | 8.1.0 | 9.1.0 | Flutter 3.47.8 Android template |
| Kotlin | 1.8.22 | 2.4.0 | Flutter 3.47.8 Android template |
| Java language level | 8 | 17 | Flutter 3.47.8 Android template |
| compileSdk / targetSdk | Flutter default (old) | 36 / 36 | Flutter 3.47.8 `FlutterExtension` |
| minSdk | 24 | 24 | Kept; new plugin set still supports 24 |
| ws | range `^8.18.0`, locked 8.22.0 | range `^8.22.0`, locked 8.22.0 | npm latest |

## API changes

- `share_plus` 13: replaced deprecated static `Share.shareXFiles` with
  `SharePlus.instance.share(ShareParams(...))`.
- Flutter 3.47: `DropdownButtonFormField.value` replaced by `initialValue`.
- `RoomClient` constructor moved to a private constructor plus factory to satisfy
  `prefer_initializing_formals` without exposing its private mutable field.
- Flutter formatter 3.13 reformatted Dart sources; no behavior change.

## Verification

- Flutter 3.47.8: `flutter analyze` clean; `flutter test` 20/20.
- Node 20: `npm ci`, `npm test` 10/10.
- Android Gradle build could not run locally: this environment has no JDK or
  Android SDK. CI is the authoritative build check.
- CI Flutter version is pinned to 3.47.8 in `flutter-ci.yml`; all other build
  settings (JDK 17, split-per-abi, release job, pubspec-derived version) remain.

## Rollback

```bash
git fetch --tags origin
git checkout v0.2.0
flutter pub get
```

To roll back only Android tooling while keeping newer Flutter, restore
`android/` from `v0.2.0` and restore the previous Flutter version in
`flutter-ci.yml`; do not mix Flutter 3.47.8 with AGP 8.1.0.

Production tag rollback is `v0.2.0`; its APK remains available at the v0.2.0
Release.
