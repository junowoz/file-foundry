#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$ROOT_DIR/FileFoundryApp/Resources/FileFoundry.entitlements"

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "Missing entitlements file: $ENTITLEMENTS" >&2
  exit 1
fi

if /usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$ENTITLEMENTS" >/dev/null 2>&1; then
  echo "File Foundry must remain outside App Sandbox so it can launch the user's local FFmpeg executable." >&2
  exit 1
fi

if /usr/libexec/PlistBuddy -c "Print :com.apple.security.network.server" "$ENTITLEMENTS" >/dev/null 2>&1; then
  echo "Network server entitlement is not allowed." >&2
  exit 1
fi

if [[ "$(/usr/libexec/PlistBuddy -c "Print" "$ENTITLEMENTS")" != "Dict {"$'\n'"}" ]]; then
  echo "File Foundry should not request signing entitlements." >&2
  exit 1
fi

echo "File Foundry requests no signing entitlements; filesystem scope is enforced by explicit pickers and application logic."
