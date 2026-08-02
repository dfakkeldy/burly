// SPDX-License-Identifier: GPL-3.0-or-later
// Durable, watch-only §5 coordinator facts. This is deliberately a single
// JSON payload so the store can stage it beside a digest or snapshot and save
// the two facts together. It belongs in V1, rather than a later schema stage:
// V1 has not shipped and this is watch-written-only shared-schema bookkeeping,
// the same established shape as `ExerciseLastPerformance`.

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
