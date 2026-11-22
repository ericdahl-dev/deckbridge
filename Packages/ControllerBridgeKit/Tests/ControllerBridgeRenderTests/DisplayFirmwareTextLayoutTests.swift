import ControllerBridgeCore
@testable import ControllerBridgeRender
import CoreText
import Foundation
import Testing

/// The drawn display firmware lays out text as this renderer does (#458): which size the title takes, where it wraps,
/// where each line is cut with an ellipsis. tools/lc6000-display-fw/test/ref/text_layout.h is this renderer's text
/// block for many cases, and the C is checked against it. This checks the file against the renderer as it is now, so a
/// layout change here that isn't carried to the chip fails. To write it: DFW_WRITE_REFS=1 swift test --filter TextLayout.
@Suite("Display firmware text layout")
struct DisplayFirmwareTextLayoutTests {
    static let file = DisplayFirmwareReferenceTests.directory.appendingPathComponent("text_layout.h")

    /// Every prefix of these, so each wrap, cut and size boundary has a case on both sides.
    static let sweeps = ["Wolfgang Amadeus Mozart Symphony No. 40 in G minor", "Office fluff affluent officer staff",
                         "Tänzer aus Tübingen und Österreich", "AVATAR Tower WAVE Yesterday To You",
                         "Supercalifragilisticexpialidocious Remix", "“Don’t” — Live at the Ænima Café…"]
    static let titles = ["Strobe", "Night Drive", "Daybreak", "Ten (Original Club Mix)", "Ten  (Original  Mix)",
                         "Mark Knight Underworld Sander Van Doorn Remix Edition", String(repeating: "x", count: 96),
                         String(repeating: "é", count: 48), "fi\u{AD}x soft hyphen in a long enough title", "A — B"]
    static let artists = ["Deadmau5", "", "Wolfgang Amadeus Mozart and the Vienna Philharmonic Orchestra",
                          "Léa Seydoux & Tänzer aus Tübingen", String(repeating: "x", count: 96)]
    static let players = ["empty", "track", "osc", "midiclip", "sequencer", "Automation",
                          "Automation Lane Controller Unit Thing"]

    static var cases: [JogDisplayContent] {
        var all: [JogDisplayContent] = []
        for sweep in sweeps { for n in 1...sweep.count { all.append(content(title: String(sweep.prefix(n)), artist: "Deadmau5")) } }
        for title in titles { all.append(content(title: title, artist: "Deadmau5")) }
        for artist in artists {
            all.append(content(title: "Strobe", artist: artist))
            all.append(content(title: "Ten (Original Club Mix)", artist: artist))
            all.append(content(title: "Night Drive", artist: artist))
        }
        for n in stride(from: 1, through: artists[2].count, by: 1) {
            all.append(content(title: "Strobe", artist: String(artists[2].prefix(n))))
        }
        for n in 1...ligatureArtist.count { all.append(content(title: "Strobe", artist: String(ligatureArtist.prefix(n)))) }
        // The same, slid along by thin letters, so the cut lands inside a ligature in some of them.
        for pad in 0..<16 {
            all.append(content(title: "Strobe", artist: String(repeating: "i", count: pad) + "Affluent offer staff fluff tattoo"))
            all.append(content(title: "Strobe", artist: String(repeating: ".", count: pad) + "Wolfgang Office fluff attitude"))
        }
        for title in nearTheSizeBoundary { all.append(content(title: title, artist: "Deadmau5")) }
        for player in players { all.append(content(title: nil, artist: nil, player: player)) }
        return all
    }

    /// Cut where a ligature (ff, fi, fl, tt) would split: CoreText keeps it whole.
    static let ligatureArtist = "Office fluff affluent officer staff stuff attitude"

    /// Titles within a fraction of a pixel of fitting at 26 px, on either side: the size choice is a <= against the
    /// chord, so these pin it. Fixed, not searched for here: ties in a search pick differently on another Mac.
    static let nearTheSizeBoundary = ["Daybreak...", "Daybreak..,", "Daybreak.,.", "AvatarWVf", "AvatarVWf", "FictionAWf"]

    @Test("The near-boundary titles are still near the boundary: the first three fit at 26 px, the rest just don't")
    func nearTheBoundary() {
        _ = JogDisplayRenderer.fontsRegistered
        let font = CTFontCreateWithName("Geist-Bold" as CFString, 26, nil)
        // The safe circle's chord at the line box's farther edge from the center (its top, 39 px above).
        let dy = max(abs(60.0 - 99), abs(60 + 26 * 1.15 - 99))
        let room = 2 * (79.0 * 79.0 - dy * dy).squareRoot()
        for (i, title) in Self.nearTheSizeBoundary.enumerated() {
            let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font, kCTKernAttributeName as NSAttributedString.Key: -0.26,
            ])), nil, nil, nil)
            #expect(JogDisplayRenderer.titleSize(title) == (i < 3 ? 26 : 20), "\(title)")
            #expect(abs(width - room) < 0.5, "\(title): \(width) against \(room)")
        }
    }

    static func content(title: String?, artist: String?, player: String = "track") -> JogDisplayContent {
        JogDisplayContent(deck: 1, color: [255, 0, 0], title: title, artist: artist, playerType: player)
    }

    static func codes(_ string: String) -> String {
        guard let data = string.data(using: .windowsCP1252) else { fatalError("\(string) isn't Windows-1252") }
        return "\"" + data.map { String(format: "\\x%02X", $0) }.joined() + "\""
    }

    static func faceName(_ line: JogDisplayRenderer.TextLine) -> String {
        switch (line.font, line.size) {
        case ("Geist-Bold", 26): return "title26"
        case ("Geist-Bold", 20): return "title20"
        case ("Geist-Medium", 16): return "caption16"
        default: fatalError("no firmware face for \(line.font) \(line.size)")
        }
    }

    /// The file's text: each case's inputs as the chip receives them, and the lines the renderer draws.
    static var table: String {
        var out = """
        // Written by DisplayFirmwareTextLayoutTests (Packages/ControllerBridgeKit): JogDisplayRenderer's text block for
        // each case, the C layout's reference (#458). Do not edit; DFW_WRITE_REFS=1 swift test --filter TextLayout.
        typedef struct { const char *face; int tracked; double top, height; const char *codes; } text_layout_line;
        typedef struct {
            const char *title, *artist, *words;
            int player, foot, count;
            text_layout_line lines[3];
        } text_layout_case;
        static const text_layout_case text_layout_cases[] = {

        """
        for content in cases {
            let title = content.title ?? ""
            let words = title.isEmpty ? JogDisplayWords.untitled(content.playerType).title : ""
            let block = JogDisplayRenderer.textBlock(content)
            let player = DrawnDisplay.Player(playerType: content.playerType).rawValue
            out += "    { \(codes(title)), \(codes(content.artist ?? "")), \(codes(words)), \(player), \(block.foot ? 1 : 0), "
            out += "\(block.lines.count), {"
            out += block.lines.map { line in
                " { \"\(faceName(line))\", \(line.tracking == 0 ? 0 : 1), \(line.top), \(line.size * line.lineHeight), "
                    + "\(codes(JogDisplayRenderer.shown(line))) }"
            }.joined(separator: ",")
            out += " } },\n"
        }
        return out + "};\n"
    }

    @Test("The firmware's text layout table is this renderer's")
    func tableIsCurrent() throws {
        let current = Self.table
        if ProcessInfo.processInfo.environment["DFW_WRITE_REFS"] == "1" {
            try current.write(to: Self.file, atomically: true, encoding: .utf8)
        }
        let saved = try? String(contentsOf: Self.file, encoding: .utf8)
        #expect(saved == current, "test/ref/text_layout.h is out of date: DFW_WRITE_REFS=1 swift test --filter TextLayout")
    }
}
