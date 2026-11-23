import CoreGraphics
import Foundation
import Testing
import UpdaterScreen

/// The size the owner set by hand is kept across launches (#761).
@Suite("Updater: the window's hand-set size is remembered")
struct HandSetSizeTests {
    static func freshDefaults() -> UserDefaults {
        let name = "HandSetSizeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Nothing set by hand yet: no size")
    func noneYet() {
        #expect(HandSetSize(defaults: Self.freshDefaults()).size == nil)
    }

    @Test("A size set by hand is read back at the next launch")
    func readBack() {
        let defaults = Self.freshDefaults()
        HandSetSize(defaults: defaults).remember(CGSize(width: 820, height: 640))
        #expect(HandSetSize(defaults: defaults).size == CGSize(width: 820, height: 640))
    }
}
