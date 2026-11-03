// SPDX-License-Identifier: GPL-3.0-or-later
// m2-03 review finding 1 (blocker, scoped by dispatcher): a second `Start`
// while a session is already `.active` must never proceed to an unsaved
// logging screen -- the store correctly refuses the second
// `saveActiveSession` (`.activeSessionAlreadyInFlight`), and the prior
// code let the (now-broken) logging screen run anyway. This view offers
// spec §4's finish-or-discard recovery choice against the EXISTING
// journaled session instead.
//
// This is deliberately NOT the full §2/§4 Resume flow -- reattaching to
// the existing session's own logging screen, with its already-logged sets
// visible, is m2-06's task. This view only closes the conflict out, so a
// fresh `Start` can proceed: Finish records the existing session as-is
// (spec §4's "another workout is running" choice), Discard drops it
// entirely. Either way, `SessionEntryView.start()` runs again afterward.
//
// Finish and Discard tell the HealthKit recorder exactly as the logging
// screen's do (spec §4, `SessionViewModel`'s file doc): Finish saves the
// session's workout before the store save so its UUID lands in the same
// write, and Discard ends the live workout without saving it. Before this,
// a Finish here wrote no workout at all, and the next Start then discarded
// the one still running.
//
// While Finish waits on HealthKit (up to about 20 s), Discard is disabled
// and the back button hidden: a discard in that window was undone by the
// store save that followed (it recreates a missing session), and leaving
// let `onResolved` start a session from a screen no longer on show. If the
// screen goes anyway, the Finish still saves, and only `onResolved` is
// skipped.
import SwiftUI
import BurlyCore
import BurlyHealth
import BurlyPersistence

struct SessionConflictView: View {
    let existing: ActiveSession
    let store: BurlyStore
    let onResolved: () -> Void

    @Environment(\.watchSettings) private var settings
    @Environment(\.sessionLogged) private var sessionLogged
    @Environment(\.workoutRecorder) private var workoutRecorder
    @State private var isFinishing = false
    @State private var isShowingDiscardConfirm = false
    @State private var errorMessage: String?
    /// The finished, workout-linked session once HealthKit has answered, so
    /// a retry after a failed store save repeats only that save and never
    /// asks HealthKit for a second workout.
    @State private var finishedEngine: SessionEngine?
    @State private var presence = ScreenPresence()

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Workout already in progress")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("sessionConflict.heading")
                Text("Finish or discard it before starting a new one.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("sessionConflict.error")
                }

                Button("Finish it", action: finish)
                    .buttonStyle(.borderedProminent)
                    .disabled(isFinishing)
                    .accessibilityIdentifier("sessionConflict.finishButton")

                if isFinishing {
                    ProgressView("Saving…")
                        .font(.caption2)
                        .accessibilityIdentifier("sessionConflict.saving")
                }

                Button("Discard it", role: .destructive) {
                    isShowingDiscardConfirm = true
                }
                .disabled(isFinishing)
                .accessibilityIdentifier("sessionConflict.discardButton")
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationBarBackButtonHidden(isFinishing)
        .onAppear { presence.isOnScreen = true }
        .onDisappear { presence.isOnScreen = false }
        .confirmationDialog(
            "Discard this workout?",
            isPresented: $isShowingDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive, action: discard)
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Records the existing session exactly as it stands -- spec §4's
    /// "another workout is running" choice offers finish, not silent
    /// discard, as the non-destructive option.
    ///
    /// A session past the §4 stale guard ends at its last activity, the
    /// same original-timestamps rule the Resume gate applies.
    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        errorMessage = nil
        // A tap means the screen is on show, whatever an earlier
        // presentation over it reported.
        presence.isOnScreen = true
        let done = FinishDependencies(
            store: store,
            workoutRecorder: workoutRecorder,
            sessionLogged: sessionLogged,
            presence: presence,
            onResolved: onResolved
        )
        if let finishedEngine {
            persist(finishedEngine, done)
            return
        }
        var engine = settings.engine(for: existing)
        do {
            if StaleSessionGuard.isStale(existing, now: Date()) {
                _ = try engine.finish(endingAt: StaleSessionGuard.lastActivity(of: existing))
            } else {
                _ = try engine.finish()
            }
        } catch {
            errorMessage = String(describing: error)
            isFinishing = false
            return
        }
        guard let workoutRecorder else {
            finishedEngine = engine
            persist(engine, done)
            return
        }
        let finished = engine
        Task {
            let session = finished.session.session
            let recording = await workoutRecorder.sessionDidFinish(
                sessionID: session.id,
                startedAt: session.startedAt,
                endedAt: session.endedAt ?? Date()
            )
            var linked = finished
            linked.linkHealthKitWorkout(recording.workoutID)
            finishedEngine = linked
            persist(linked, done)
        }
    }

    /// Saves through what `finish()` captured when it was tapped, not this
    /// view's environment, which a screen no longer on show reads as its
    /// defaults.
    private func persist(_ engine: SessionEngine, _ done: FinishDependencies) {
        do {
            try done.store.saveActiveSession(engine.session)
            done.workoutRecorder?.sessionWasLogged(sessionID: engine.session.id)
            done.sessionLogged(engine.session.id)
            guard done.presence.isOnScreen else { return }
            done.onResolved()
        } catch {
            errorMessage = String(describing: error)
            isFinishing = false
        }
    }

    private func discard() {
        errorMessage = nil
        do {
            _ = try store.deleteSession(id: existing.session.id)
            workoutRecorder?.sessionDidDiscard(sessionID: existing.session.id)
            onResolved()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

/// Whether `SessionConflictView` is still the screen on show. A reference,
/// so a Finish that waited on HealthKit reads the current value rather
/// than the one its closure captured.
@MainActor
private final class ScreenPresence {
    var isOnScreen = true
}

/// What a Finish needs once HealthKit answers, captured at the tap.
@MainActor
private struct FinishDependencies {
    let store: BurlyStore
    let workoutRecorder: SessionWorkoutRecorder?
    let sessionLogged: @MainActor @Sendable (UUID) -> Void
    let presence: ScreenPresence
    let onResolved: () -> Void
}
