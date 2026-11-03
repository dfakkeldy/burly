#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Scripts/check-exported-ipa.sh IPA_PATH
#
# Checks an App Store .ipa exported from a Scripts/archive-release.sh archive
# before anything uploads it: both apps verify, both are signed for
# distribution, and each still carries every entitlement its target declares
# (HealthKit). The archive is signed ad hoc and the export re-signs it, so a
# dropped entitlement would otherwise show up only as a broken Health prompt
# on a tester's watch.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "check-exported-ipa: FAIL: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: $0 IPA_PATH"
IPA="$1"
[[ -f "$IPA" ]] || fail "no such .ipa: $IPA"

WORK="$(mktemp -d -t burly-ipa-check)"
trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$IPA" "$WORK"

PHONE_APP="$WORK/Payload/BurlyPhone.app"
WATCH_APP="$PHONE_APP/Watch/BurlyWatch.app"
[[ -d "$PHONE_APP" ]] || fail ".ipa has no Payload/BurlyPhone.app"
[[ -d "$WATCH_APP" ]] || fail ".ipa has no embedded Watch/BurlyWatch.app"

codesign --verify --deep --strict "$PHONE_APP" || fail "codesign --verify failed"

check_app() {
  local app="$1" declared="$2" name signed
  name="${app#"$WORK/Payload/"}"
  codesign -dvv "$app" 2>&1 | grep -q '^Authority=Apple Distribution: ' \
    || fail "$name is not signed with an Apple Distribution certificate"
  signed="$WORK/$(basename "$app").entitlements.plist"
  codesign -d --entitlements - --xml "$app" 2>/dev/null > "$signed" \
    || fail "cannot read the entitlements of $name"
  # Every declared key with its declared value. The export adds its own keys
  # (application-identifier, team, beta-reports-active); those are fine.
  /usr/bin/python3 -I - "$declared" "$signed" "$name" <<'PY'
import plistlib, sys
declared_path, signed_path, name = sys.argv[1:]
with open(declared_path, "rb") as f:
    declared = plistlib.load(f)
with open(signed_path, "rb") as f:
    signed = plistlib.load(f)
missing = [key for key, value in declared.items() if signed.get(key) != value]
if missing:
    sys.exit(f"check-exported-ipa: FAIL: {name} lost declared entitlements: {', '.join(missing)}")
if signed.get("get-task-allow") is True:
    sys.exit(f"check-exported-ipa: FAIL: {name} is signed debuggable (get-task-allow)")
print(f"check-exported-ipa: {name}: distribution-signed, keeps {', '.join(sorted(declared))}")
PY
}

check_app "$WATCH_APP" "$REPO_ROOT/BurlyWatch/BurlyWatch.entitlements"
check_app "$PHONE_APP" "$REPO_ROOT/BurlyPhone/BurlyPhone.entitlements"
echo "check-exported-ipa: OK: $(basename "$IPA")"
