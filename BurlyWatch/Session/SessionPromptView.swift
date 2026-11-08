// SPDX-License-Identifier: MIT
// A full-screen question in place of the logging pager, for the two §4
// lifecycle rules that interrupt a running session: the stale-session
// guard ("Still working out?") and "another workout is running". Drawn as
// ordinary body content of `LoggingScreenView`, like `SaveFailureView`,
// not as a sheet: nothing here is chained off another presentation's
// dismissal (the m2-03 lesson recorded in `LoggingScreenView`).
import SwiftUI

struct SessionPromptView: View {
    let systemImage: String
    let heading: String
    let detail: Text
    /// Prefix for the leaf identifiers: `<prefix>.heading`,
    /// `<prefix>.primaryButton`, `<prefix>.secondaryButton`,
    /// `<prefix>.destructiveButton`.
    let identifier: String
    let primaryTitle: String
    let onPrimary: () -> Void
    let secondaryTitle: String
    let onSecondary: () -> Void
    var destructiveTitle: String?
    var onDestructive: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(heading)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("\(identifier).heading")
                detail
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("\(identifier).detail")

                Button(action: onPrimary) {
                    Text(primaryTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("\(identifier).primaryButton")

                Button(action: onSecondary) {
                    Text(secondaryTitle).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("\(identifier).secondaryButton")

                if let destructiveTitle, let onDestructive {
                    Button(role: .destructive, action: onDestructive) {
                        Text(destructiveTitle).frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("\(identifier).destructiveButton")
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview("Stale") {
    SessionPromptView(
        systemImage: "clock.badge.exclamationmark",
        heading: "Still working out?",
        detail: Text("Last set \(Date.now.addingTimeInterval(-5_400), format: .relative(presentation: .named))"),
        identifier: "staleSession",
        primaryTitle: "End workout",
        onPrimary: {},
        secondaryTitle: "Keep going",
        onSecondary: {}
    )
}
