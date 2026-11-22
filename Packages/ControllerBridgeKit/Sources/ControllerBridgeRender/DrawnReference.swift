// The drawn display firmware's reference images (#571), produced one way: tools/lc6000-display-fw/test/ref/manifest.json
// lists every one with the renderer inputs that make it, jog-reference renders them from it (make_refs.sh), and the
// Kit's DisplayFirmwareReferenceTests checks each against the renderer now, from the same list.
import ControllerBridgeCore
import Foundation

public enum DrawnReference {
    /// One reference: its file, the deck and its text, and the live parts, as the manifest gives them.
    public struct Entry: Decodable, Sendable {
        public let file: String
        public let deck: Int
        public let color: [Int]
        /// A Syndicate player type, or nil for none (the C side has no type name for "other").
        public let player: String?
        public let stale: Bool?
        public let title: String?, artist: String?, key: String?
        public let bpm: Double?
        public let beat: Int?, needle: Int?
        /// [level, peak], 0-127 each.
        public let meter: [Int]?
        public let phase: Int?
        /// [elapsed, length] in seconds.
        public let time: [Int]?
        /// "red" or "white": the warning's look.
        public let look: String?
        /// 216 for the whole drawn image (the band round the frame); the 198 frame otherwise.
        public let canvas: Int?

        /// The image's side in pixels.
        public var size: Int { canvas ?? JogDisplayRenderer.size }
    }

    private struct Manifest: Decodable { let references: [Entry] }

    /// The manifest's entries, in its order.
    public static func manifest(at url: URL) throws -> [Entry] {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)).references
    }

    public enum Failure: Error { case badEntry(String) }

    /// The entry's deck and live parts, for the renderer.
    public static func inputs(_ entry: Entry) throws -> (JogDisplayContent, DrawnLive) {
        var content = JogDisplayContent(deck: entry.deck, color: entry.color, playerType: entry.player)
        content.stale = entry.stale ?? false
        content.title = entry.title
        content.artist = entry.artist
        content.key = entry.key
        content.bpm = entry.bpm
        let look: JogTrackTime.Look
        switch entry.look {
        case nil: look = .normal
        case "red": look = .warningRed
        case "white": look = .warningWhite
        default: throw Failure.badEntry("\(entry.file): look \(entry.look!)")
        }
        if let meter = entry.meter, meter.count != 2 { throw Failure.badEntry("\(entry.file): meter") }
        if let time = entry.time, time.count != 2 { throw Failure.badEntry("\(entry.file): time") }
        if let canvas = entry.canvas, canvas != JogDisplayRenderer.drawnSize { throw Failure.badEntry("\(entry.file): canvas") }
        let live = DrawnLive(beat: entry.beat, needle: entry.needle,
                             meter: entry.meter.map { DrawnLive.Meter(level: $0[0], peak: $0[1]) }, phase: entry.phase,
                             time: entry.time.map { DrawnLive.Time(elapsed: $0[0], length: $0[1]) }, look: look)
        return (content, live)
    }

    /// The entry's image as RGB rows, top first: JogDisplayRenderer.drawnImage cropped to the 198 frame, or the whole
    /// 216 drawn image with canvas 216. The image is opaque, so premultiplied RGBA is RGB.
    public static func render(_ entry: Entry) -> [UInt8] {
        guard let (content, live) = try? inputs(entry) else { return [] }
        let rgba = JogDisplayRenderer.drawnImage(content, live: live)
        let drawn = JogDisplayRenderer.drawnSize, size = entry.size, inset = (drawn - size) / 2
        var rgb: [UInt8] = []
        rgb.reserveCapacity(size * size * 3)
        for y in 0..<size {
            for x in 0..<size {
                let pixel = ((y + inset) * drawn + x + inset) * 4
                rgb += rgba[pixel..<pixel + 3]
            }
        }
        return rgb
    }

    /// The entry's image as a binary PPM (P6), as the C tests read it.
    public static func ppm(_ entry: Entry) -> Data {
        var data = Data("P6\n\(entry.size) \(entry.size)\n255\n".utf8)
        data.append(contentsOf: render(entry))
        return data
    }
}
