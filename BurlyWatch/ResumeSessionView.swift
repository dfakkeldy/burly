// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 "Always-On & recovery": "Relaunch with an `.active` session in
// store → Resume screen (session intact to the last logged set) +
// `recoverActiveWorkoutSession()` reattach. Declining resume = normal
// end-workout summary path." Spec §3: the rest timer's `endDate` "survives
// crash and appears correctly on Resume" -- this view is the entry point
// that lets a lifter actually see that (m2-06; m2-03 explicitly scoped this
// out, see `SessionEntryView`'s file doc).
//
// Deliberately thin: this view only names the *choice* (resume, or don't)
// and pushes `HomeRoute.resume(sessionID:enterSummary:)` -- reattaching to
// the session, computing its summary, and every Finish/Keep going/Discard
// rule live in `SessionEngine`/`SessionViewModel`/`SessionSummaryBuilder`
// exactly as they do for a session that was never interrupted. This view
// adds no session-flow policy of its own; "declining resume" is not a
// different code path, just `LoggingScreenView`'s existing
// `startInSummary: true` seam (see that file's doc).
import SwiftUI

struct ResumeSessionView: View {
    let preview: WatchHomeViewModel.ResumablePreview

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Resume workout?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("resumeSession.heading")
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("resumeSession.details")

                NavigationLink(
                    value: HomeRoute.resume(sessionID: preview.sessionID, enterSummary: false)
                ) {
                    Text("Resume")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("resumeSession.resumeButton")

                // §2: "Declining resume = normal end-workout summary path"
                // -- not a discard, not an instant finish. `SessionEntryView`
                // reattaches the same session and lands straight on the
                // Finish/Keep going/Discard preview instead of the pager.
                NavigationLink(
                    value: HomeRoute.resume(sessionID: preview.sessionID, enterSummary: true)
                ) {
                    Text("Not now")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("resumeSession.notNowButton")
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Burly")
    }

    private var detailText: String {
        let sets = preview.loggedSetCount
        let setWord = sets == 1 ? "set" : "sets"
        let name = preview.routineName ?? "Empty session"
        return "\(name) — \(sets) \(setWord) logged"
    }
}

#Preview {
    NavigationStack {
        ResumeSessionView(
            preview: WatchHomeViewModel.ResumablePreview(
                sessionID: UUID(),
                routineName: "Leg Day",
                startedAt: .now,
                loggedSetCount: 2
            )
        )
    }
}
