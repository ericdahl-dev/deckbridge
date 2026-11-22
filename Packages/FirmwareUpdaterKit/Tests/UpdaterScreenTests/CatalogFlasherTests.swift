import DeviceFinder
import FirmwareCatalog
import FirmwareModel
import Foundation
import PanelFlasher
import Synchronization
import Testing
import UpdaterScreen

/// Opens nothing: records the port asked for, then fails as `error`.
final class RefusingOpener: LineOpener, @unchecked Sendable {
    let error: FlashError
    private let ports = Mutex<[String]>([])
    var asked: [String] { ports.withLock { $0 } }

    init(_ error: FlashError) { self.error = error }

    func open(_ port: String) async throws -> any BootloaderLine {
        ports.withLock { $0.append(port) }
        throw error
    }
}

/// The app's flasher (#687): the catalog's newest panel image, on the port the panel has on USB.
@Suite("Updater: the catalog's panel image, on the panel's port")
struct CatalogFlasherTests {
    /// A catalog folder with two panel builds; the newest, 1.10.0, is a real app image's shape.
    static func catalog() throws -> Catalog {
        let folder = FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
            {"panel": [{"version": "1.2.0", "sha": "aaaaaaa", "image": "old.bin"},
                       {"version": "1.10.0", "sha": "bbbbbbb", "image": "new.bin"}], "lc6000": []}
            """.utf8).write(to: folder.appending(path: "catalog.json"))
        var image = [UInt8](repeating: 0, count: 64)
        image[0] = 0xE9
        image[12] = 0x09
        try Data(image).write(to: folder.appending(path: "new.bin"))
        try Data([0xE9]).write(to: folder.appending(path: "old.bin"))
        return try Catalog(directory: folder)
    }

    static func flasher(_ rig: Rig, _ opener: RefusingOpener) throws -> CatalogFlasher {
        CatalogFlasher(catalog: try catalog(), usb: rig.usb, finder: rig.finder, opener: opener)
    }

    @Test("Offered: the newest version for an older shipped build; with a note for a build the app doesn't know; none when current")
    func offers() throws {
        let flasher = try Self.flasher(Rig(), RefusingOpener(.portBusy))
        #expect(flasher.offer(for: PanelBuild(sha: "aaaaaaa")) == PanelUpdateOffer(version: "1.10.0", note: nil))
        #expect(flasher.offer(for: PanelBuild(sha: "1234567"))
            == PanelUpdateOffer(version: "1.10.0", note: "This panel runs a build this app doesn't know: a development build, or one newer than this app."))
        #expect(flasher.offer(for: PanelBuild(sha: "bbbbbbb")) == nil)
    }

    @Test("It opens the port the panel has on USB, and a busy port fails as busy")
    func opensThePanelsPort() async throws {
        let rig = Rig()
        UpdaterScreenTests.panel(rig, printing: [])
        let opener = RefusingOpener(.portBusy)
        let flasher = try Self.flasher(rig, opener)
        let steps = Mutex<[PanelUpdate.Step]>([])
        await flasher.flash { step in steps.withLock { $0.append(step) } }
        #expect(opener.asked == [UpdaterScreenTests.port])
        #expect(steps.withLock { $0 } == [.connecting, .failed(.portBusy)])
    }

    @Test("No panel port on USB: the cable is lost, and nothing is opened")
    func noPort() async throws {
        let opener = RefusingOpener(.portBusy)
        let flasher = try Self.flasher(Rig(), opener)
        let steps = Mutex<[PanelUpdate.Step]>([])
        await flasher.flash { step in steps.withLock { $0.append(step) } }
        #expect(opener.asked.isEmpty)
        #expect(steps.withLock { $0 } == [.failed(.lineLost)])
    }
}
