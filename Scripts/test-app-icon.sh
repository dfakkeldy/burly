#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$REPO_ROOT/Scripts/generate-app-icon.swift"
VALIDATOR="$REPO_ROOT/Scripts/validate-app-icon.swift"
PHONE_ICON="$REPO_ROOT/BurlyPhone/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
WATCH_ICON="$REPO_ROOT/BurlyWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
TEST_DIR="$(mktemp -d -t burly-app-icon-test)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  echo "app-icon-test: FAIL: $*" >&2
  exit 1
}

[[ -f "$GENERATOR" ]] || fail "missing generator: $GENERATOR"
[[ -f "$VALIDATOR" ]] || fail "missing validator: $VALIDATOR"

swift "$GENERATOR" "$TEST_DIR/first.png"
swift "$GENERATOR" "$TEST_DIR/second.png"

cmp -s "$TEST_DIR/first.png" "$TEST_DIR/second.png" \
  || fail "two fresh generations differ"
cmp -s "$TEST_DIR/first.png" "$PHONE_ICON" \
  || fail "iPhone AppIcon.png is stale"
cmp -s "$TEST_DIR/first.png" "$WATCH_ICON" \
  || fail "Watch AppIcon.png is stale"

for icon in "$TEST_DIR/first.png" "$PHONE_ICON" "$WATCH_ICON"; do
  swift "$VALIDATOR" "$icon"
  file "$icon" | grep -q 'PNG image data, 1024 x 1024, 8-bit/color RGB' \
    || fail "$icon is not a 1024x1024 8-bit RGB PNG"
done

echo "app-icon-test: PASS"
