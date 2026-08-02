# HANDOFF — burly-m4-03

## Outcome

Implemented a standalone `BurlySyncAdapters` SwiftPM target for the §5
WCSession channels and the watch background-task completion invariant. The
target has no package dependencies and imports no Burly domain/protocol module.

Branch/head verified before work: `task/burly-m4-03` at
`691b4d769e4a4dbb91042beb0ef5c543ba0afc1d`.

Per task instruction, nothing was committed, pushed, or published.

## Cross-engine review fix round

- **Duplicate system-task identity (MAJOR):**
  `SystemWCRefreshBackgroundTask.completionID` now derives from
  `ObjectIdentifier` of the wrapped
  `WKWatchConnectivityRefreshBackgroundTask`. Re-wrapping the same system
  task therefore reaches the coordinator with the same key and its existing
  retention guard makes the second retain a no-op. The coordinator's concrete
  key/storage types now use `ObjectIdentifier` as well.
  - Pin: `duplicateWrapperIdentity` constructs two wrapper objects around one
    fake system task, verifies one retained obligation, opens the activation +
    queue-drained gate twice, and observes exactly one
    `setTaskCompletedWithSnapshot(false)` call.
- **Same-identity snapshot retransmit (MINOR):** before storing a new file
  transfer at an exact `(version, generation)` key, the adapter removes and
  cancels any existing handle at that key. Strictly older versions retain the
  existing supersession behavior; same-version/different-generation handles
  remain distinct.
  - Pin: `sameIdentitySnapshotRetransmit` proves the old exact-key handle is
    cancelled once, the replacement remains live, and later exact cancellation
    reaches the replacement rather than the old handle.
- **Adapter import-parser spellings (NIT):** the parser pin now covers the full
  hardened set used by the machine seam: leading whitespace, `_exported` and
  `testable` attributes, every access modifier requested by review, attributed
  modifier combinations, declaration-kind imports, and prose rejection.
- **Machine manifest guard (ADJACENT):** the marker now anchors on
  `.target(\n            name: "BurlySyncMachine"`, so the same-named product
  cannot satisfy the search. Any `dependencies:` inserted before the next
  target declaration is now inside the inspected slice and fails the guard.

## Module layout

- `BurlyKit/Sources/BurlySyncAdapters/WCSessionTransportTypes.swift`
  - Injected snapshot/session/digest kind strings.
  - Opaque `Data` commands and received-envelope events.
  - Sendable transfer/error/metadata values.
  - `@MainActor` fakeable WCSession protocol.
  - Caller-supplied actor event sink.
- `BurlyKit/Sources/BurlySyncAdapters/WCSessionAdapter.swift`
  - Maps watch session commands to `transferUserInfo`.
  - Maps phone snapshot commands to `transferFile` and exact
    `(version, generation)` cancellation.
  - Automatically cancels older-version snapshot transfers.
  - Maps digest publication to `updateApplicationContext`.
  - Serializes callback facts onto the caller's actor.
  - Surfaces accepted, held-needs-update, malformed, activation, queue, and
    transfer-finished facts without fabricating delivery/ack events.
- `BurlyKit/Sources/BurlySyncAdapters/SystemWCSessionTransport.swift`
  - Concrete iOS/watchOS `WCSession` wrapper.
  - Writes opaque snapshot bytes to a temporary file for `transferFile` and
    deletes the sender file from the finish callback.
  - Captures Sendable callback values before explicitly hopping from Apple's
    callback queue to `MainActor`.
  - Observes activation and `hasContentPending`, snapshotting both facts
    together to avoid stale cross-callback combinations.
- `BurlyKit/Sources/BurlySyncAdapters/WCBackgroundTaskCompletionState.swift`
  - Pure generic state machine: retain every task; drain only while activated
    and `hasContentPending == false`.
  - Main-actor coordinator owns concrete retained tasks and completes each
    exactly once with `snapshot: false`.
- `BurlyKit/Sources/BurlySyncAdapters/SystemWCRefreshBackgroundTask.swift`
  - watchOS wrapper and direct adapter overload for
    `WKWatchConnectivityRefreshBackgroundTask`.
- `BurlyKit/Tests/BurlySyncAdaptersTests/`
  - Fake WCSession/transfer/background-task support.
  - Channel, cancellation, callback, envelope-outcome, concurrency seam, and
    background burst/out-of-order tests.
- `BurlyKit/Package.swift`
  - Adds the dependency-free library and test targets.

## Seam and isolation mechanism

- Build seam: `BurlySyncAdapters` declares no SwiftPM dependencies.
- Policy seam: tests scan every adapter source import and allow only
  `Foundation`, `WatchConnectivity`, and `WatchKit`; the parser itself is
  pinned for attributed/access-level import spellings. A separate manifest
  test inspects the target declaration (not the same-named product).
- Wire seam: callers inject `WCSessionPayloadKinds` plus an
  `OpaqueEnvelopeInspector`. The adapter never imports `BurlyCore`,
  `BurlySync`, or `BurlySyncMachine`, and never decodes a payload.
- Isolation: mutable WCSession/transfer/task ownership is `@MainActor`.
  Upward events are Sendable values serialized onto an actor conforming to
  `WCSessionAdapterEventSink`, supplied by the caller. No Model/ModelContext
  Sendability behavior is used as confinement.
- Compile checks: event/command/state types are asserted `Sendable`; the
  guarded `BURLY_ADAPTER_NEGATIVE_ISOLATION_COMPILE_CHECK` deliberately fails
  when a nonisolated caller invokes `WCSessionAdapter.activate()` directly.

## Acceptance evidence

1. **Three WCSession channels**
   - Session: opaque envelope `Data` in `transferUserInfo`, with session UUID
     metadata; outstanding IDs are surfaced at activation for retry dedupe.
   - Snapshot: opaque bytes written to a file and sent with `transferFile`;
     older versions cancel automatically, explicit cancel is exact-keyed by
     `(version, generation)`.
   - Digest: opaque bytes in `updateApplicationContext`, preserving WC's
     latest-wins semantics.
2. **Callback mapping without reachability gating**
   - Activation exposes `alreadyQueuedSessionIDs` even when reachability is
     false. Durable channels never consult `isReachable` before enqueueing.
   - Received file/user-info/context payloads surface as opaque `Data` plus
     transport metadata after injected inspection.
3. **Full snapshot transfer identity**
   - Bookkeeping dictionary key is `SnapshotTransferIdentity(version,
     generation)`.
   - Finish event echoes that complete identity on success, failure, and late
     cancelled callbacks; the machine can reject stale generations.
4. **No fabricated delivery proof**
   - Public events say `sessionTransferFinished` /
     `snapshotTransferFinished` with `reportedSuccess` and an optional
     transport error. There is no delivered/acked/confirmed event.
   - Tests pin successful and failed callbacks as transport facts only.
5. **Background-task invariant under bursts**
   - Pure tests retain bursts of 256 IDs and drain all once, in order, only
     after activation plus aggregate queue drain.
   - Coordinator test retains 128 concrete fake tasks, proves zero early
     completions, exactly one `setTaskCompletedWithSnapshot(false)` each, and
     zero retained tasks after drain.
   - Adapter test proves successful session/snapshot finish callbacks do not
     complete the background tasks; only the atomically observed
     `hasContentPending == false` gate does.
   - Both notification orders (`pending false` before activation and
     activation before `pending false`) are pinned.
   - Simulator/device budget proof remains m4-06 as specified; this task lands
     the unit-testable core and concrete watchOS bridge.

## Verification receipts

### Fix-round required full package test (2026-08-02)

The literal `cd BurlyKit && swift test` attempt was denied before compilation:
the managed sandbox makes `~/.cache/clang/ModuleCache` read-only, and after
redirecting that cache SwiftPM's nested `sandbox-exec` was also denied. The
successful equivalent kept the outer managed sandbox active, redirected only
disposable module caches, and disabled SwiftPM's inner sandbox:

```sh
cd BurlyKit && \
CLANG_MODULE_CACHE_PATH=/tmp/burly-m4-03-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/burly-m4-03-module-cache \
swift test --disable-sandbox
```

Result: exit 0. Final-tree build completed in 0.28 s. Swift Testing reported:

```text
Test run with 631 tests in 66 suites passed after 7.552 seconds.
```

The existing opt-in stats benchmark and migration spike were skipped by their
default guards. Per the fix-round instruction, the migration-spike invocation
is left to the dispatcher in an environment that permits it.

Focused fix-round command (same cache/sandbox accommodation):

```sh
swift test --disable-sandbox --package-path BurlyKit \
  --filter 'BurlySyncAdaptersTests|SyncMachineSeamTests'
```

Result: exit 0, `22 tests in 4 suites passed after 0.011 seconds`.

`git diff --check`: exit 0, no output.

The optional generic-watchOS compile could not resolve the local package under
this sandbox: Xcode lost CoreSimulator services and attempted writes to the
read-only user SwiftPM/module caches. No source compilation diagnostic was
emitted. The dispatcher should rerun the existing generic-watchOS command.

### Original implementation full package test

Command:

```sh
cd BurlyKit && swift test
```

Result: exit 0. Build completed in 3.97 s. Swift Testing reported:

```text
Test run with 629 tests in 66 suites passed after 5.551 seconds.
```

The stats benchmark and migration spike were skipped in this default run by
their existing opt-in guards.

### Original implementation migration spike (historical receipt)

The literal command first hit the managed sandbox because SwiftPM attempted to
write `~/.cache/clang/ModuleCache`. Redirecting the module cache then exposed
SwiftPM's nested `sandbox-exec`, which the outer sandbox denies. The successful
equivalent kept the outer managed sandbox active, redirected only disposable
caches, and disabled SwiftPM's inner sandbox:

```sh
cd BurlyKit && \
BURLY_RUN_MIGRATION_SPIKE=1 \
CLANG_MODULE_CACHE_PATH=/tmp/burly-m4-03-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/burly-m4-03-module-cache \
swift test --disable-sandbox --filter MigrationSpikeTests
```

Result: exit 0. Swift Testing reported:

```text
Test run with 2 tests in 1 suite passed after 0.274 seconds.
```

SwiftPM emitted read-only user-cache warnings, and CoreData emitted its existing
store-changed-notification registration warnings; both migration tests passed.

### Original implementation platform compilation (historical receipt)

Commands:

```sh
xcodebuild -scheme BurlySyncAdapters -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/burly-m4-03-ios-derived build CODE_SIGNING_ALLOWED=NO

xcodebuild -scheme BurlySyncAdapters -destination 'generic/platform=watchOS' \
  -derivedDataPath /tmp/burly-m4-03-watch-derived build CODE_SIGNING_ALLOWED=NO
```

Results: both exit 0 under Xcode 26.6 / iOS 26.5 SDK / watchOS 26.5 SDK. The
watchOS build includes the concrete `WKWatchConnectivityRefreshBackgroundTask`
wrapper.

### Original implementation focused and compile-time checks

- `swift test --filter BurlySyncAdaptersTests`: exit 0,
  `17 tests in 3 suites passed after 0.010 seconds`.
- Negative isolation opt-in: exited 1 as intended with
  `call to main actor-isolated instance method 'activate()' in a synchronous
  nonisolated context`.
- `git diff --check`: exit 0, no output.

## Ambiguities interpreted

- `applySnapshot` and `applyDigest` are binding-executor/store commands, not
  WCSession effects. They are intentionally not executed by this below-executor
  transport module. A received accepted envelope is serialized onto the
  caller-supplied actor, where the m4-04/m4-05 executor decodes/routes it and
  performs the atomic store apply required by `SyncMachineBinding.swift`.
- “Payload kinds injected” means both the three discriminator strings and the
  envelope inspection function are injected. The adapter may compare the
  inspector's returned kind with the channel's configured kind, but it never
  interprets payload contents.
- “Newer snapshot cancels any outstanding snapshot transfer” is treated as a
  strict version increase. Same-version replacements remain distinct by
  generation; an exact same-identity retransmit cancels its existing handle
  before replacement, while other exact-key cancellation remains machine-led.
- Reachability changes are surfaced for diagnostics only. They never gate the
  durable queue/file/context channels.

## Dispatcher state

Expected fix-round working-tree changes are only:

- `BurlyKit/Sources/BurlySyncAdapters/SystemWCRefreshBackgroundTask.swift`
- `BurlyKit/Sources/BurlySyncAdapters/WCBackgroundTaskCompletionState.swift`
- `BurlyKit/Sources/BurlySyncAdapters/WCSessionAdapter.swift`
- `BurlyKit/Tests/BurlySyncAdaptersTests/AdapterTestSupport.swift`
- `BurlyKit/Tests/BurlySyncAdaptersTests/SyncAdapterSeamTests.swift`
- `BurlyKit/Tests/BurlySyncAdaptersTests/WCBackgroundTaskCompletionTests.swift`
- `BurlyKit/Tests/BurlySyncAdaptersTests/WCSessionAdapterTests.swift`
- `BurlyKit/Tests/BurlySyncMachineTests/SyncMachineSeamTests.swift`
- this handoff file

No commit was attempted because the task explicitly reserves commit ownership
for the dispatcher.
