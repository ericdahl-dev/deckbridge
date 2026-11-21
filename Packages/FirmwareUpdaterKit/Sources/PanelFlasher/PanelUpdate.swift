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
    public func run(_ image: [UInt8], on port: String, wipeWiFi: Bool, report: @Sendable (Step) -> Void) async {
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
            try await bootloader.checkPartitionTable()
            try await bootloader.speedUp()
            try await bootloader.flashApp(image, wipeWiFi: wipeWiFi) { report(.writing($0)) }
            report(.restarting)
            await bootloader.release()
            await line.close()
        } catch {
            await line.close()
            return report(.failed(Self.reason(error)))
        }
        if case .onSerial(let build) = await finder.find().panel { return report(.done(build)) }
        report(.done(nil))
    }

    static func reason(_ error: any Error) -> FlashError {
        if let flash = error as? FlashError { return flash }
        if error is CancellationError { return .cancelled }
        return .lineLost
    }
}
