// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySync
// Device/cloud sync layer for Burly.

import BurlyCore

public enum BurlySync {
    /// The highest envelope schema this build understands. Receivers hold a
    /// payload whose version is greater than this rather than attempting a
    /// partial decode with assumptions from an older app build.
    public static let currentSchemaVersion = 1

    public static let placeholder = "BurlySync"
}
