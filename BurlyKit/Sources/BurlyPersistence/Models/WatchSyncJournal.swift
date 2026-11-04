// SPDX-License-Identifier: GPL-3.0-or-later
// Durable, watch-only §5 coordinator facts. This is deliberately a single
// JSON payload so the store can stage it beside a digest or snapshot and save
// the two facts together. It went into V1, rather than a later schema stage,
// because V1 had not shipped then and this is watch-written-only shared-schema
// bookkeeping, the same established shape as `ExerciseLastPerformance`. V1 is
// frozen since TestFlight 0.9.1.

import Foundation
import SwiftData

extension BurlySchemaV1 {
    @Model
    final class WatchSyncJournal {
        static let singletonKey = "watchSync"

        @Attribute(.unique) var key: String
        var payload: Data

        init(key: String = singletonKey, payload: Data) {
            self.key = key
            self.payload = payload
        }
    }
}
