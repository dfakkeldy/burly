# Burly

Burly is a free, open-source, watch-first lifting tracker for iPhone and
Apple Watch.

**Status: under active development.** Nothing here is ready for daily
use. There is no App Store listing and no Fastlane pipeline.

## What's on `main`

The phone History tab (`HistoryTabView`) and session-detail editor
(`HistorySessionDetailView`) landed on `main` on 2026-08-29 in
[PR #4](https://github.com/dfakkeldy/burly/pull/4)
(`48ee5a257d`). Logged sessions can be reviewed and edited there; those
edits preserve the linked HealthKit workout identifier.

## Simulator acceptance

[PR #5](https://github.com/dfakkeldy/burly/pull/5) merged the
`replaceText` / `hasFocus` fix (`974d33c58f`, 2026-08-29).

The `Simulator acceptance` job in `.github/workflows/ci.yml` only runs
on pushes to `main`, so a green PR check is not simulator acceptance.
`main` is still red:
[run 33263690697](https://github.com/dfakkeldy/burly/actions/runs/33263690697)
(includes #5) failed in
`testHistoryEditsAdvanceRevisionAndPreserveHealthKitLink`
(`Expected edit to persist exactly revision 5`).

## License

Burly is licensed under the [GNU General Public License v3.0 or later](LICENSE),
with an [App Store distribution exception](LICENSE-APP-STORE-EXCEPTION.md) that
permits distribution through Apple's App Store while keeping the complete
source available to everyone under the GPL.
