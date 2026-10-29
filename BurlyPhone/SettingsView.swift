// SPDX-License-Identifier: GPL-3.0-or-later
// Settings tab (spec §9 Phone IA: "display unit (kg/lb), global rest
// default, HealthKit status row (§4), Hevy import (§8), about/licenses (GPL
// text)"; planning task m5-05).
//
// Every row either does what it says or says plainly that it is
// informational — no control that silently does nothing:
//
// - Display unit is a real, persisted phone preference. Weights are still
//   stored in kg; only iPhone rendering and entry change (§9 acceptance #2).
// - Rest default is read-only. A configurable global default only matters
//   if it reaches the watch, which needs a §5 snapshot wire change; until
//   then the row shows the §3 default the watch actually uses and points at
//   the per-exercise rest that *is* editable, in each routine.
// - Apple Health is informational, and says what this build actually does.
//   Spec §4 puts HealthKit authorization and workout saving on the watch,
//   at first session start, but that is not wired yet: no target carries
//   the HealthKit entitlement or the Health purpose strings, and no watch
//   code uses BurlyHealth. Until it is, the row says saving is coming
//   rather than claiming it (review finding: the first draft described
//   saving and a permission prompt that never happen). When the watch side
//   ships, restore §4's wording here. The phone reads no authorization
//   status either way; §4 asks for a quiet row that never nags.

import BurlyCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(DisplayUnitPreference.storageKey) private var unit = DisplayUnitPreference.defaultUnit
    @Environment(\.openURL) private var openURL

    /// Burly's public repository (the GPL "Corresponding Source").
    static let sourceCodeURL = URL(string: "https://github.com/dfakkeldy/burly")!

    var body: some View {
        // Mounted bare in MainTabView, so the tab owns its navigation stack
        // (as HistoryTabView does) for the Import and Licenses pushes.
        NavigationStack {
            // Import stays first, where the original stub put it: it is the
            // one row a new user arrives looking for, and keeping it above
            // the fold keeps it in a lazy List's accessibility tree on the
            // first screen (BurlyPhoneUITests' tab smoke looks for it there).
            List {
                importSection
                unitSection
                restSection
                healthSection
                aboutSection
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: Units

    private var unitSection: some View {
        Section {
            // Checkmark rows rather than a segmented control: full names
            // wrap instead of clipping at accessibility text sizes, and each
            // option carries its own identifier and selected trait.
            ForEach(WeightUnit.allCases, id: \.self) { option in
                Button {
                    unit = option
                } label: {
                    HStack {
                        Text(Self.unitName(option))
                            .foregroundStyle(.primary)
                        Spacer()
                        if option == unit {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(option == unit ? .isSelected : [])
                .accessibilityIdentifier("settingsTab.unitOption.\(option.rawValue)")
            }
        } header: {
            Text("Weight unit")
        } footer: {
            Text("Burly stores every weight in kilograms and converts for display, so switching never changes your history. Apple Watch shows kilograms for now.")
        }
    }

    static func unitName(_ unit: WeightUnit) -> String {
        switch unit {
        case .kilograms: "Kilograms (kg)"
        case .pounds: "Pounds (lb)"
        }
    }

    // MARK: Rest

    private var restSection: some View {
        Section {
            LabeledContent {
                Text(Self.restDefaultText)
            } label: {
                Label("Default rest", systemImage: "timer")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settingsTab.restDefaultRow")
        } header: {
            Text("Rest timer")
        } footer: {
            Text("Used for any exercise without its own rest time. You can change rest for each exercise in its routine.")
        }
    }

    /// The §3 global default, as a timer reads ("1:30").
    static var restDefaultText: String {
        Duration.seconds(RestDuration.globalDefault).formatted(.time(pattern: .minuteSecond))
    }

    // MARK: Apple Health

    private var healthSection: some View {
        Section {
            Label {
                Text("Saving workouts to Apple Health from Apple Watch is coming in a later update.")
            } icon: {
                Image(systemName: "heart.text.square")
                    .foregroundStyle(.pink)
            }
            .accessibilityIdentifier("settingsTab.healthRow")

            Button {
                openHealth()
            } label: {
                Label("Open Health", systemImage: "arrow.up.forward.app")
            }
            .accessibilityHint("Opens the Health app.")
            .accessibilityIdentifier("settingsTab.openHealth")
        } header: {
            Text("Apple Health")
        } footer: {
            Text("Your sets are kept in Burly. When saving to Health arrives, Apple Watch will ask for permission the first time you start a workout.")
        }
    }

    /// Opens the Health app, falling back to Burly's page in Settings.
    ///
    /// Uses the completion form of `openURL` rather than `canOpenURL`:
    /// `canOpenURL` answers false for any scheme missing from
    /// `LSApplicationQueriesSchemes`, which this generated Info.plist does
    /// not declare, so it would always take the fallback.
    private func openHealth() {
        guard let healthURL = URL(string: "x-apple-health://") else { return }
        openURL(healthURL) { accepted in
            guard !accepted, let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(settingsURL)
        }
    }

    // MARK: Import

    private var importSection: some View {
        Section {
            NavigationLink {
                ImportPlaceholderView()
            } label: {
                Label("Import from Hevy", systemImage: "tray.and.arrow.down")
            }
            .accessibilityIdentifier("settingsTab.importRow")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.versionString)
                .accessibilityIdentifier("settingsTab.versionRow")

            Link(destination: Self.sourceCodeURL) {
                Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .accessibilityHint("Opens Burly's public repository on GitHub.")
            .accessibilityIdentifier("settingsTab.sourceCodeLink")

            NavigationLink {
                LicensesView()
            } label: {
                Label("Licenses", systemImage: "doc.text")
            }
            .accessibilityIdentifier("settingsTab.licensesRow")
        } header: {
            Text("About")
        } footer: {
            Text("Burly is free software under the GNU GPL, version 3 or later.")
        }
    }

    /// "1.0 (1)": marketing version and build number.
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
}
