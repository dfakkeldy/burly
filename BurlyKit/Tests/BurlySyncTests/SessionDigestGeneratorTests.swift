import Foundation
import Testing
import BurlyCore
@testable import BurlySync

@Suite("§5 digest generator completeness")
struct SessionDigestGeneratorTests {
    @Test("generated digests contain exactly the exercises with logged history")
    func absenceProvesNoHistory() {
        let ids = (0..<8).map { _ in UUID() }
        for mask in 0..<(1 << ids.count) {
            let sessions = ids.enumerated().map { index, id in
                let logged = mask & (1 << index) != 0
                let sets = logged ? [SetRecordData(order: 0, weight: Weight(kg: Double(index + 1)), reps: 5, completedAt: Date(timeIntervalSince1970: Double(index)))] : []
                return SessionData(startedAt: .now, state: .logged, origin: .live, items: [SessionItemData(exerciseID: id, order: 0, sets: sets)])
            }
            let derived = SessionDigestGenerator.lastPerformance(from: sessions)
            #expect(Set(derived.map(\.exerciseID)) == Set(ids.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil }))
        }
    }
}
