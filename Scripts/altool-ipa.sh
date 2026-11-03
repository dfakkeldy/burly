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
# altool logs each server-side HTTP 5xx it retries as an "ERROR:" line
# ("... received status code 500; internal server error"), then carries on.
# On 2026-11-03 every dry run printed several and still ended "VERIFY
# SUCCEEDED with no errors". Those lines, and only those, are retry notices
# rather than verdicts: they count as warnings when altool also printed its
# success line below, and still fail the step when it did not. 90683 and
# every other error line fail regardless.
# The exact shape of those notices, e.g. "ERROR: [ContentDelivery.Uploader.
# 97AC14400] GET UPLOAD STATE (ASSET_SPI): received status code 500;
# internal server error. (MCTJQGUYKIMWUZMYMG2ZA6WKLQ) (500)". Anything that
# merely mentions a 5xx (an "UPLOAD FAILED ... status code 500" banner, say)
# is not a retry notice and still fails.
RETRY='ERROR: \[[A-Za-z0-9._]+\] [^:]+: received status code 5[0-9]{2}; [A-Za-z ]+\. \([A-Z0-9]+\) \(5[0-9]{2}\)[[:space:]]*$'
VERDICT_CODE='itms-[0-9]+|90683|fail'
if [[ "$MODE" == validate ]]; then
  SUCCESS='verify succeeded|no errors validating'
else
  SUCCESS='upload succeeded|no errors uploading'
fi
error_lines="$(grep -Ei "$ERR" "$LOG" || true)"
# A retry notice has exactly that shape and no ITMS code or "fail" in it.
retries="$(printf '%s\n' "$error_lines" | grep -E "$RETRY" | grep -Eiv "$VERDICT_CODE" || true)"
if [[ -n "$retries" ]]; then
  errors="$(printf '%s\n' "$error_lines" | grep -Fxv -f <(printf '%s\n' "$retries") || true)"
else
  errors="$error_lines"
fi
if [[ -n "$retries" ]] && ! grep -Eiq "$SUCCESS" "$LOG"; then
  errors+="$retries"
fi
errors="$(printf '%s' "$errors" | sed '/^[[:space:]]*$/d')"
if (( rc != 0 )) || [[ -n "$errors" ]]; then
  if [[ "$MODE" == upload ]]; then
    # A transient server error line can sit next to a success banner (seen
    # on a validation, 2026-11-03), so the build may have arrived anyway.
    fail "App Store Connect $DOING reported an error (altool exit $rc); check TestFlight for this build number before re-running, since the upload may have reached it"
  fi
  fail "App Store Connect $DOING failed (altool exit $rc); see $(basename "$LOG")"
fi
{ grep -Ei "$WARN" "$LOG" || true; printf '%s\n' "$retries"; } | sed '/^$/d' | sed -n '1,10s/^/::warning::/p'

# Pass only on positive evidence. Xcode 26.6 prints "VERIFY SUCCEEDED with
# no errors" and "No errors validating archive" for a validation (seen in
# this lane's first dry run), and the matching UPLOAD / uploading lines for
# an upload (SUCCESS above). Looser wording such as "not successfully
# validated" must not pass; if a later Xcode words it differently, this
# fails loudly rather than reporting an unconfirmed result as a pass.
grep -Eiq "$SUCCESS" "$LOG" || fail "altool printed no recognised success line; read $(basename "$LOG")"
echo "App Store Connect $DOING succeeded for $(basename "${IPAS[0]}")"
