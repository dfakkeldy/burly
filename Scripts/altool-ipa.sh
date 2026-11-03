#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Scripts/altool-ipa.sh validate|upload EXPORT_DIR LOG_FILE
#
# Sends the one App Store .ipa in EXPORT_DIR to App Store Connect with
# altool: `validate` runs the server-side checks an upload gets but creates
# no build (the release dry run); `upload` uploads it for TestFlight (a tag
# push). Both read the same .ipa that Scripts/check-exported-ipa.sh checked,
# so the file Apple receives is the file that passed the checks.
#
# Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 on disk) in the
# environment. altool finds an API key only as AuthKey_<key ID>.p8 in
# $API_PRIVATE_KEYS_DIR, so this makes a correctly named copy in a private
# temporary directory and removes it on exit. Classic flag spelling (-f, -t,
# --apiKey, --apiIssuer), as fastlane uses with Xcode 26's altool; no
# --verbose, which can echo identifiers into this public log. The key ID and
# issuer ID are replaced with *** in everything printed or logged.
set -euo pipefail

fail() {
  echo "::error::$*"
  exit 1
}

[[ $# -eq 3 ]] || fail "usage: $0 validate|upload EXPORT_DIR LOG_FILE"
MODE="$1"
EXPORT_DIR="$2"
LOG="$3"
case "$MODE" in
  validate) ACTION=--validate-app; DOING="validation" ;;
  upload) ACTION=--upload-app; DOING="upload" ;;
  *) fail "unknown mode '$MODE' (expected validate or upload)" ;;
esac
: "${ASC_KEY_ID:?ASC_KEY_ID is required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"
: "${ASC_KEY_PATH:?ASC_KEY_PATH is required}"
[[ -f "$ASC_KEY_PATH" ]] || fail "no API key file at ASC_KEY_PATH"

shopt -s nullglob
IPAS=("$EXPORT_DIR"/*.ipa)
if (( ${#IPAS[@]} != 1 )); then
  fail "expected exactly one .ipa in $EXPORT_DIR, found ${#IPAS[@]}"
fi

umask 077
# Next to the key itself, so a cleanup that removes the key's directory
# (release.yml's always-run step) also removes this copy if we are killed.
KEYS="$(mktemp -d "$(dirname "$ASC_KEY_PATH")/private_keys.XXXXXX")"
trap 'rm -rf "$KEYS"' EXIT
cp "$ASC_KEY_PATH" "$KEYS/AuthKey_${ASC_KEY_ID}.p8"

scrub() { perl -pe 'for my $v (@ENV{qw(ASC_KEY_ID ASC_ISSUER_ID)}) { s/\Q$v\E/***/g if length($v // "") }'; }
# Which altool ran, for reading the log later.
{ xcrun --find altool; xcrun altool --version || true; } 2>&1 | scrub

set +e
API_PRIVATE_KEYS_DIR="$KEYS" xcrun altool "$ACTION" \
  -f "${IPAS[0]}" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
  2>&1 | scrub | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e

# Xcode 26's altool has exited 0 on server-side errors, so this fails on
# error text as well as on the exit code. Failure text in the forms altool
# and Transporter print: a log-level "ERROR:", "*** Error", "ERROR
# ITMS-<code>", an NSError dump, the "VERIFY FAILED" / "UPLOAD FAILED"
# banners, "Failed to validate package", and 90683 as a whole number (no
# letter, digit or underscore either side, so not inside a hex delivery ID,
# "0x90683" or "ticket90683"). 90683 fails even on a WARNING line, on
# purpose: App Store Connect refused Free Lunch's first upload outright with
# it, and this app embeds a Watch app the same way. Other bare ITMS codes are
# not matched because warnings carry them too.
ERR='(^|[^[:alnum:]_])error:|\*\*\* ?error|(^|[^[:alnum:]_])error[[:space:]]+itms-[0-9]+|error domain=|(validation|verif(y|ication)|upload) failed|failed to validate|(^|[^[:alnum:]_])90683([^[:alnum:]_]|$)'
WARN='(^|[^[:alnum:]_])warn(ing)?:|\*\*\* ?warning|(^|[^[:alnum:]_])warning[[:space:]]+itms-[0-9]+'
if (( rc != 0 )) || grep -Eiq "$ERR" "$LOG"; then
  if [[ "$MODE" == upload ]]; then
    # A transient server error line can sit next to a success banner (seen
    # on a validation, 2026-11-03), so the build may have arrived anyway.
    fail "App Store Connect $DOING reported an error (altool exit $rc); check TestFlight for this build number before re-running, since the upload may have reached it"
  fi
  fail "App Store Connect $DOING failed (altool exit $rc); see $(basename "$LOG")"
fi
{ grep -Ei "$WARN" "$LOG" || true; } | head -n 10 | sed 's/^/::warning::/'

# Pass only on positive evidence. Xcode 26.6 prints "VERIFY SUCCEEDED with
# no errors" and "No errors validating archive" for a validation (seen in
# this lane's first dry run), and the matching UPLOAD / uploading lines for
# an upload. Looser wording such as "not successfully validated" must not
# pass; if a later Xcode words it differently, this fails loudly rather than
# reporting an unconfirmed result as a pass.
if [[ "$MODE" == validate ]]; then
  SUCCESS='verify succeeded|no errors validating'
else
  SUCCESS='upload succeeded|no errors uploading'
fi
grep -Eiq "$SUCCESS" "$LOG" || fail "altool printed no recognised success line; read $(basename "$LOG")"
echo "App Store Connect $DOING succeeded for $(basename "${IPAS[0]}")"
