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
import SwiftUI
import BurlyCore
import BurlyPersistence

struct SessionConflictView: View {
    let existing: ActiveSession
    let store: BurlyStore
    let onResolved: () -> Void

    @State private var isFinishing = false
    @State private var isShowingDiscardConfirm = false
    @State private var errorMessage: String?

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

                Button("Discard it", role: .destructive) {
                    isShowingDiscardConfirm = true
                }
                .accessibilityIdentifier("sessionConflict.discardButton")
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
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
    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        errorMessage = nil
        do {
            var engine = SessionEngine(session: existing)
            _ = try engine.finish()
            try store.saveActiveSession(engine.session)
            onResolved()
        } catch {
            errorMessage = String(describing: error)
            isFinishing = false
        }
    }

    private func discard() {
        errorMessage = nil
        do {
            _ = try store.deleteSession(id: existing.session.id)
            onResolved()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
