#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Scripts/archive-release.sh ARCHIVE_PATH [XCODEBUILD_ARG ...]
#
# Archives BurlyPhone, with its embedded watch app, in Release for a generic
# iOS device WITHOUT a signing certificate, then signs the archived bundles
# ad hoc with their entitlements. `xcodebuild -exportArchive` with cloud
# signing does the real signing afterwards (release.yml).
#
# Why not let the archive sign: with automatic signing, archive signs with an
# Apple Development identity, and an empty CI runner has none, so
# -allowProvisioningUpdates made Apple mint a new "Apple Development: Created
# via API" certificate on every run. The team hit Apple's certificate cap on
# 2026-11-03 and archives failed (dfakkeldy/grok-bots#873). The export signs
# with the cloud-managed Apple Distribution certificate, which is not counted
# against that cap, so an archive that needs no certificate ends the problem.
#
# Why sign ad hoc by hand: an archive built with CODE_SIGNING_ALLOWED=NO
# carries no entitlements, and the export would then sign with only the base
# set it derives from the profile, silently dropping HealthKit. Ad hoc signing
# through build settings is refused for the iOS SDK, so this script signs the
# archived bundles itself, inside out, and checks the result. The export keeps
# the entitlements it finds in the ad hoc signature.
#
# Extra arguments go to `xcodebuild archive` unchanged (build setting
# overrides such as MARKETING_VERSION=..., or -derivedDataPath). This script
# never talks to Apple: no API key, no -allowProvisioningUpdates.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "archive-release: $*" >&2; }
fail() {
  echo "archive-release: FAIL: $*" >&2
  exit 1
}

[[ $# -ge 1 ]] || fail "usage: $0 ARCHIVE_PATH [XCODEBUILD_ARG ...]"
ARCHIVE="$1"
shift

# Every bundle with code in the archive, mapped to the entitlements file its
# target declares (CODE_SIGN_ENTITLEMENTS in the project). A bundle this list
# does not name fails the run rather than shipping without its entitlements.
PHONE_APP_REL="Products/Applications/BurlyPhone.app"
WATCH_APP_REL="$PHONE_APP_REL/Watch/BurlyWatch.app"
PHONE_ENTITLEMENTS="$REPO_ROOT/BurlyPhone/BurlyPhone.entitlements"
WATCH_ENTITLEMENTS="$REPO_ROOT/BurlyWatch/BurlyWatch.entitlements"

for file in "$PHONE_ENTITLEMENTS" "$WATCH_ENTITLEMENTS"; do
  [[ -f "$file" ]] || fail "missing entitlements file: $file"
  plutil -lint -s "$file" || fail "unreadable entitlements file: $file"
  # Build-setting references such as $(AppIdentifierPrefix) are expanded by
  # Xcode's own signing, which this script replaces. None are used today;
  # adding one must come with expansion here, not a silently literal value.
  if grep -q '\$[({]' "$file"; then
    fail "$file uses a build-setting reference this script does not expand"
  fi
done

log "archiving BurlyPhone (Release, generic iOS device, no signing certificate)"
xcodebuild archive \
  -project "$REPO_ROOT/Burly.xcodeproj" \
  -scheme BurlyPhone \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  "$@" \
  CODE_SIGNING_ALLOWED=NO

PHONE_APP="$ARCHIVE/$PHONE_APP_REL"
WATCH_APP="$ARCHIVE/$WATCH_APP_REL"
[[ -d "$PHONE_APP" ]] || fail "archive has no $PHONE_APP_REL"
[[ -d "$WATCH_APP" ]] || fail "archive has no $WATCH_APP_REL"

# Refuse nested bundles nobody planned for: an app extension or a second app
# would need its own entitlements, and an embedded framework or dylib has to
# be signed before the bundle that contains it.
unexpected="$(
  find "$PHONE_APP" \( -name '*.app' -o -name '*.appex' -o -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' \) \
    -not -path "$PHONE_APP" -not -path "$WATCH_APP" -print
)"
[[ -z "$unexpected" ]] || fail "archive contains bundles this script does not sign:
$unexpected"

sign() {
  local bundle="$1" entitlements="$2"
  log "signing ${bundle#"$ARCHIVE/"} ad hoc with $(basename "$entitlements")"
  codesign --force --sign - --timestamp=none --generate-entitlement-der \
    --entitlements "$entitlements" "$bundle"
}

# Inside out: the watch app is code nested in the phone app.
sign "$WATCH_APP" "$WATCH_ENTITLEMENTS"
sign "$PHONE_APP" "$PHONE_ENTITLEMENTS"

codesign --verify --deep --strict "$PHONE_APP" || fail "codesign --verify failed for the archived app"

# The signature must carry exactly the declared entitlements.
check_entitlements() {
  local bundle="$1" expected="$2" actual
  actual="$(mktemp -t burly-entitlements)"
  codesign -d --entitlements - --xml "$bundle" 2>/dev/null > "$actual" \
    || { rm -f "$actual"; fail "cannot read entitlements of ${bundle#"$ARCHIVE/"}"; }
  if ! diff -q <(plutil -convert xml1 -o - "$expected") <(plutil -convert xml1 -o - "$actual") > /dev/null; then
    echo "expected:" >&2; plutil -p "$expected" >&2
    echo "signed:" >&2; plutil -p "$actual" >&2
    rm -f "$actual"
    fail "${bundle#"$ARCHIVE/"} is not signed with $(basename "$expected")"
  fi
  rm -f "$actual"
}
check_entitlements "$WATCH_APP" "$WATCH_ENTITLEMENTS"
check_entitlements "$PHONE_APP" "$PHONE_ENTITLEMENTS"

log "OK: $ARCHIVE is archived without a certificate and both apps carry their entitlements"
