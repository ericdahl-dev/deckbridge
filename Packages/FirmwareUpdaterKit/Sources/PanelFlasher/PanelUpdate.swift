import DeviceFinder
import FirmwareModel

/// Opens a panel's serial port for the flasher; throws FlashError.portBusy when another app holds it.
public protocol LineOpener: Sendable {
    func open(_ port: String) async throws -> any BootloaderLine
}

public struct PanelUpdate: Sendable {
    public enum Step: Sendable, Equatable {
        case connecting
        case writing(Double)
        case restarting
        case done(PanelBuild?)
        case failed(FlashError)
    }

    let opener: any LineOpener
    let finder: DeviceFinder

    public init(opener: any LineOpener, finder: DeviceFinder) {
        self.opener = opener
        self.finder = finder
    }

    /// Puts `image` on the panel at `port` (#687): opens the cable, resets the panel into its ROM bootloader, refuses a
    /// wrong chip or a board without the deck panel's partition table before writing, writes and verifies app0 and
    /// otadata (and wipes nvs only if asked), resets the panel into its new app, then reads the build it now runs.
    /// Every way out leaves the panel running and the line closed. Ends with `.done` or `.failed`.
    /// The panel build's bootloader and partition table, for making a blank or foreign board a deck panel.
    public struct BootParts: Sendable {
        public let bootloader: [UInt8]
        public let partitions: [UInt8]
        public init(bootloader: [UInt8], partitions: [UInt8]) {
            self.bootloader = bootloader
            self.partitions = partitions
        }
    }

    public func run(_ image: [UInt8], on port: String, wipeWiFi: Bool, boot: BootParts? = nil, makeDeckPanel: Bool = false,
                    report: @Sendable (Step) -> Void) async {
        guard Self.isPanelApp(image) else { return report(.failed(.notAPanelImage)) }
        report(.connecting)
        let line: any BootloaderLine
        do {
            line = try await opener.open(port)
        } catch {
            return report(.failed(Self.reason(error)))
        }
        let bootloader = Bootloader(line: line)
        do {
            try await bootloader.connect()
            try await bootloader.checkChip()
            // A board without the deck panel's table is made one only when the owner confirmed it and the catalog has
            // the panel build's bootloader and table; otherwise it is refused here, before anything is written.
            let isDeckPanel = try await bootloader.isDeckPanel(boot?.partitions)
            guard isDeckPanel || (makeDeckPanel && boot != nil) else { throw FlashError.notADeckPanel }
            try await bootloader.speedUp()
            // Said before the first erase, so the app stops offering Cancel before the app slot is touched (#744).
            report(.writing(0))
            if let boot, !isDeckPanel {
                try await bootloader.makeDeckPanel(image, bootloader: boot.bootloader, partitions: boot.partitions) {
                    report(.writing($0))
                }
            } else {
                try await bootloader.flashApp(image, wipeWiFi: wipeWiFi) { report(.writing($0)) }
            }
            report(.restarting)
            await bootloader.release()
            await line.close()
        } catch {
            await bootloader.release()
            await line.close()
            let reason = Self.reason(error), written = await bootloader.hasWritten
            return report(.failed(reason == .canceled && written ? .canceledWhileWriting : reason))
        }
        if case .onSerial(let build) = await finder.find().panel { return report(.done(build)) }
        report(.done(nil))
    }

    /// app0's size (tools/deck-panel/partitions.csv): a bigger image would erase into app1.
    static let app0Size = 0x64_0000

    /// An ESP32-S3 app image that fits app0: magic E9 and chip id 9 at bytes 12-13 of esp_image_header_t.
    static func isPanelApp(_ image: [UInt8]) -> Bool {
        image.count > 13 && image.count <= app0Size && image[0] == 0xE9 && image[12] == 0x09 && image[13] == 0x00
    }

    static func reason(_ error: any Error) -> FlashError {
        if let flash = error as? FlashError { return flash }
        if error is CancellationError { return .canceled }
        return .lineLost
    }
}

extension PanelUpdate.Step {
    /// What the owner reads for this step: what is happening, or what went wrong and what to do.
    public var text: String {
        switch self {
        case .connecting: return "Connecting to the deck panel…"
        case .writing(let share): return "Writing the new firmware: \(Int(share * 100))%"
        case .restarting: return "Restarting the deck panel…"
        case .done(let build?):
            return build.version.map { "Updated: the panel now runs \($0) (build \(build.sha))" }
                ?? "Updated: the panel now runs build \(build.sha)"
        case .done(nil): return "Updated. The panel's build wasn't read: unplug it and plug it back in to see it"
        case .failed(let error): return Self.text(for: error)
        }
    }

    static func text(for error: FlashError) -> String {
        let mayNotStart = "The panel may not start: try again before unplugging it."
        switch error {
        case .portBusy:
            return "DeckBridge is using the panel's cable. Turn off \"Send over the USB cable\" in DeckBridge, then try again."
        case .wrongBoard(let what): return "This board isn't a deck panel (\(what)). Nothing was written."
        case .notADeckPanel: return "This board doesn't have the deck panel's layout. Nothing was written."
        case .noBootloader, .refused, .noAnswer: return "The panel didn't answer. Unplug it, plug it back in, and try again."
        case .writeFailed(let address): return "Writing failed at 0x\(String(address, radix: 16, uppercase: true)). \(mayNotStart)"
        case .verifyFailed: return "The written firmware didn't check out. \(mayNotStart)"
        case .canceled: return "Canceled. The panel was restarted."
        case .canceledWhileWriting: return "Canceled while writing. \(mayNotStart)"
        case .lineLost: return "The cable was lost. Plug the panel back in and try again."
        case .notAPanelImage: return "The firmware file isn't a deck panel image. Nothing was written."
        }
    }
}
