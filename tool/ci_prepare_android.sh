#!/usr/bin/env bash
# CI-only helper: fills missing Gradle wrapper and Android resources using the
# installed Flutter SDK. Never run in the restricted authoring environment.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
flutter create --platforms=android --project-name heartrate --org com.example "$TMP/scaffold"
cp -R "$TMP/scaffold/android/gradle" "$ROOT/android/"
cp "$TMP/scaffold/android/gradlew" "$ROOT/android/"
cp "$TMP/scaffold/android/gradlew.bat" "$ROOT/android/"
cp -R "$TMP/scaffold/android/app/src/main/res" "$ROOT/android/app/src/main/"
cp "$TMP/scaffold/android/app/src/debug/AndroidManifest.xml" "$ROOT/android/app/src/debug/"
cp "$TMP/scaffold/android/app/src/profile/AndroidManifest.xml" "$ROOT/android/app/src/profile/"
echo 'CI Android scaffold merged; custom manifest and Kotlin/Gradle files preserved.'
