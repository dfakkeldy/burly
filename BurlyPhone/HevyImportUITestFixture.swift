// SPDX-License-Identifier: GPL-3.0-or-later
// DEBUG-only stand-in for the system document picker on the Hevy import
// screen (task m7-02). XCUITest cannot drive the Files picker, so when this
// launch-environment key is set, "Choose CSV File" reads a bundled,
// SYNTHETIC export instead of presenting the picker.
//
// Same posture as PhoneDemoSeed's scenario key: compiled out of release
// builds entirely, matched literally by the UI test target (which runs
// out-of-process and cannot share code), and fail-closed — a present but
// unrecognized value is an error the screen shows, never a silent fall-
// through to the real picker. The CSV itself lives in `Preview Content`,
// which `DEVELOPMENT_ASSET_PATHS` strips from archived builds, and is
// excluded from Release builds by name (see the BurlyPhone target's
// `EXCLUDED_SOURCE_FILE_NAMES`). It is invented data, not anyone's history.

import Foundation

#if DEBUG
enum HevyImportUITestFixture {
    /// Matched literally by BurlyPhoneUITests/ImportUITests.swift.
    static let environmentKey = "BURLY_PHONE_UI_TEST_HEVY_FIXTURE"

    enum Fixture: String {
        /// `Preview Content/HevySyntheticFixture.csv`: three synthetic
        /// workouts with every dropped-data category represented. Its
        /// expected preview numbers are pinned by BurlyKit's
        /// `HevyImportPlanTests.appUITestFixtureParsesToTheNumbersTheUITestAsserts`
        /// and asserted again by ImportUITests.
        case synthetic

        var resourceName: String {
            switch self {
            case .synthetic: "HevySyntheticFixture"
            }
        }
    }

    enum FixtureError: Error, LocalizedError {
        case unrecognizedFixture(String)
        case resourceMissing(String)

        var errorDescription: String? {
            switch self {
            case .unrecognizedFixture(let raw):
                "UI-test fixture \"\(raw)\" is not a known fixture."
            case .resourceMissing(let name):
                "UI-test fixture \(name).csv is missing from the app bundle."
            }
        }
    }

    /// `nil` only when the key is absent (a real launch): present the
    /// picker. Otherwise the fixture's bytes, or why they can't be had.
    static func requestedData(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<Data, Error>? {
        guard let raw = environment[environmentKey] else { return nil }
        guard let fixture = Fixture(rawValue: raw) else {
            return .failure(FixtureError.unrecognizedFixture(raw))
        }
        guard let url = Bundle.main.url(forResource: fixture.resourceName, withExtension: "csv") else {
            return .failure(FixtureError.resourceMissing(fixture.resourceName))
        }
        return Result { try Data(contentsOf: url) }
    }
}
#endif
