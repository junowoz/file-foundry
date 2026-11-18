#!/usr/bin/env bash
# Builds the Android app and adds FileFoundry-Android.apk to an existing GitHub release,
# then updates the release's SHA256SUMS with the APK line.
# Usage: scripts/publish_android.sh <tag>   (for example v1.3.0)
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <tag>" >&2
  exit 1
fi

TAG="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APK_NAME="FileFoundry-Android.apk"
APK_PATH="$DIST_DIR/$APK_NAME"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$DIST_DIR"

(cd "$ROOT_DIR/android" && ./gradlew assembleRelease)
cp "$ROOT_DIR/android/app/build/outputs/apk/release/app-release.apk" "$APK_PATH"

gh release upload "$TAG" "$APK_PATH" --clobber

# Fetch the current SHA256SUMS (the Mac build writes the first line), then replace or add the APK line.
gh release download "$TAG" --pattern SHA256SUMS --dir "$WORK_DIR" --clobber
touch "$WORK_DIR/SHA256SUMS"
{
  grep -v "  $APK_NAME\$" "$WORK_DIR/SHA256SUMS" || true
  (cd "$DIST_DIR" && shasum -a 256 "$APK_NAME")
} > "$WORK_DIR/SHA256SUMS.new"
mv "$WORK_DIR/SHA256SUMS.new" "$WORK_DIR/SHA256SUMS"

gh release upload "$TAG" "$WORK_DIR/SHA256SUMS" --clobber
echo "Published $APK_NAME to $TAG"
