# Burly

Free, open-source (GPL-3.0-or-later, with an App Store exception), watch-first
lifting tracker for iPhone and Apple Watch. Under active development.

## Layout

- `BurlyKit/`: Swift package with the core, persistence, sync, HealthKit, and
  import modules. Most logic and tests live here.
- `BurlyPhone/`, `BurlyWatch/`: app targets (schemes `BurlyPhone`,
  `BurlyWatch`) in `Burly.xcodeproj`.
- `DECISIONS.md`: running decision log, newest entry first, dated in local
  time. Read it before revisiting a settled design choice.
- `docs/superpowers/`: specs and plans.

## Commands

```bash
cd BurlyKit && swift test
Scripts/acceptance-sim.sh     # the CI simulator acceptance gate
```

Change build or acceptance steps in `Scripts/acceptance-sim.sh`, not in a
separate CI-only script.

## Rules

- Source files start with `// SPDX-License-Identifier: GPL-3.0-or-later`.
- This repo is public. Planning lives in the private `~/Developer/health-apps`
  repo; never copy personal health details from there into this one.
