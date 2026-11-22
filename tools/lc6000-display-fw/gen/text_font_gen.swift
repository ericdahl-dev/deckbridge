// Rasterizes the Geist faces the drawn display's text uses (#458) into 4-bit coverage, with CoreText, the way
// JogDisplayRenderer draws them, and writes the measures the layout needs in font units, so the C sums them exactly:
//   swift tools/lc6000-display-fw/gen/text_font_gen.swift tools/lc6000-display-fw/src/font_text.h \
//       tools/lc6000-display-fw/test/ref/text_widths.h
// Run from the repo root. Fonts: Packages/ControllerBridgeKit/Sources/ControllerBridgeRender/Fonts (SIL OFL 1.1).
//
// What CoreText does with the renderer's lines, measured (#458):
// - The renderer always sets the kern attribute (tracking × size). A kern of 0 turns the font's kerning off, so only
//   the one-line 26 px title (tracking -0.01 em) is kerned; every other line is advances alone.
// - Geist's ligatures, with kerning on or off: ff, fi, fl and tt, taken greedily left to right one pair at a time
//   ("ffi" is ff then i). Its arrow ligatures (->, <--, <->) also swap glyphs by context, and aren't copied.
// - A soft hyphen (0xAD) draws nothing and takes no room.
// - The baseline's y is snapped (a glyph drawn 0.18 and 0.53 px past a pixel rasterizes the same), so one bitmap per
//   glyph and x phase serves every line of a face. x snaps down to a fraction of a pixel, measured per face, and each
//   glyph is kept at every phase.
// - Tracking is added after every glyph, a ligature counting as one.
// Characters are Windows-1252 codes, as the text message carries them. A code Geist has no glyph for, and 0x81 (the
// host's "no glyph"), draw Geist's own .notdef: the box.
import CoreGraphics
import CoreText
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let fontDir = "Packages/ControllerBridgeKit/Sources/ControllerBridgeRender/Fonts"

/// The picture's shared numbers (#571), from layout/layout.json: the generator reads the same table the renderer does.
let layoutTable: [String: String] = {
    let url = URL(fileURLWithPath: "tools/lc6000-display-fw/layout/layout.json")
    guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let constants = json["constants"] as? [[String: Any]] else { fail("Can't read \(url.path)") }
    var table: [String: String] = [:]
    for constant in constants { if let name = constant["name"] as? String { table[name] = constant["value"] as? String } }
    return table
}()

func layout(_ name: String) -> CGFloat {
    guard let text = layoutTable[name], let value = Double(text) else { fail("layout.json has no \(name)") }
    return CGFloat(value)
}

func layoutColor(_ name: String) -> Int {
    guard let text = layoutTable[name], let value = Int(text, radix: 16) else { fail("layout.json has no color \(name)") }
    return value
}
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else { fail("Usage: text_font_gen.swift <font_text.h> <text_widths.h>") }

func loadFont(_ file: String, postScriptName: String, size: CGFloat) -> CTFont {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: "\(fontDir)/\(file)") as CFURL)
            as? [CTFontDescriptor], let descriptor = descriptors.first else { fail("Can't read \(fontDir)/\(file)") }
    let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    guard CTFontCopyPostScriptName(font) as String == postScriptName else { fail("\(file) is not \(postScriptName)") }
    return font
}

func color(_ hex: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

/// A line as the renderer makes it: the kern attribute always set, to tracking × size.
func makeLine(_ string: String, font: CTFont, tracking: CGFloat) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTKernAttributeName as NSAttributedString.Key: tracking * CTFontGetSize(font),
    ]))
}

/// The same line with the font's kerning on, for measuring the kerned face's pairs.
func kernedLine(_ string: String, font: CTFont) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
}

func width(_ line: CTLine) -> Double { CTLineGetTypographicBounds(line, nil, nil, nil) }

func glyphIDs(_ line: CTLine) -> [CGGlyph] {
    var all: [CGGlyph] = []
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        all += glyphs
    }
    return all
}

/// A Windows-1252 code's character, or nil for the five codes it leaves undefined.
func character(_ code: Int) -> String? {
    String(data: Data([UInt8(code)]), encoding: .windowsCP1252).flatMap { $0.unicodeScalars.count == 1 ? $0 : nil }
}

let undefined: Set<Int> = [0x81, 0x8D, 0x8F, 0x90, 0x9D]
let softHyphen = 0xAD
let ligatures = ["ff", "fi", "fl", "tt"]

struct Face {
    let name: String, file: String, postScriptName: String, size: CGFloat
    let ink: Int, ground: Int
    /// The middle of the line box the face is drawn in: its baseline is middle + (ascent - descent) / 2.
    let middle: CGFloat
    let tracking: CGFloat
    let kerned: Bool
    let about: String
}

let ground = 0x0B0B0B, text = 0xEDEDEA, caption = 0xBDBDBD
let faces = [
    Face(name: "title26", file: "Geist-Bold.ttf", postScriptName: "Geist-Bold", size: 26, ink: text, ground: ground,
         middle: 60 + 26 * 1.15 / 2, tracking: -0.01, kerned: true,
         about: "the one-line title (tracked -0.01 em, kerned), line box top 60, 1.15; an untitled deck's words (neither), top 66, 1.1"),
    Face(name: "title20", file: "Geist-Bold.ttf", postScriptName: "Geist-Bold", size: 20, ink: text, ground: ground,
         middle: 54 + 20 * 1.1 / 2, tracking: 0, kerned: false,
         about: "the title at 20 px, line box tops 54, 78 and 64, 1.1: all on the same pixel phase"),
    Face(name: "caption16", file: "Geist-Medium.ttf", postScriptName: "Geist-Medium", size: 16, ink: caption, ground: ground,
         middle: 94 + 16 * 1.15 / 2, tracking: 0, kerned: false, about: "the artist, line box tops 94 and 103, 1.15; an untitled deck's caption, top 100, 1.1"),
    Face(name: "mono18", file: "GeistMono-SemiBold.ttf", postScriptName: "GeistMono-SemiBold", size: layout("keySize"),
         ink: text, ground: ground, middle: layout("keyCenterY"), tracking: 0, kerned: false,
         about: "key and BPM in drawn mode (#524), line box middle 140.5"),
]

let pad = 16, box = 64
var header = """
// Generated by tools/lc6000-display-fw/gen/text_font_gen.swift from the Geist fonts (SIL OFL 1.1,
// Packages/ControllerBridgeKit/Sources/ControllerBridgeRender/Fonts/Geist-OFL.txt). Do not edit. Regenerate from the
// repo root (see the generator for the command). The text faces (#458): 4-bit coverage, one x phase, each face
// rasterized at the one baseline it is drawn at; advances, kerning and tracking in font units.
#ifndef DFW_FONT_TEXT_H
#define DFW_FONT_TEXT_H
#include <stdint.h>

#include "text.h"

/// One rasterization of a glyph: its bitmap's place from the glyph origin (left, and top above the baseline), its size,
/// and where its coverage starts (4 bits a pixel, high nibble first, each row starting on a byte).
typedef struct { int8_t left, top; uint8_t width, height; uint32_t offset; } dfw_text_bitmap;
/// The most x phases a face has: CoreText snaps a glyph's x down to 1/phases of a pixel.
#define DFW_TEXT_PHASES_MAX 4
/// One glyph: its advance in font units, and its bitmap at each x phase.
typedef struct { int16_t advance; dfw_text_bitmap phase[DFW_TEXT_PHASES_MAX]; } dfw_text_glyph;
/// A kerning pair: (left glyph << 8) | right glyph, and its kern in font units. Sorted by pair.
typedef struct { uint16_t pair; int16_t units; } dfw_kern;
/// The code a glyph index of 255 marks: nothing drawn, no room (the soft hyphen).
#define DFW_NO_GLYPH 255
/// The face itself: text.h names it, so the font data stays out of everything but text.c.
struct dfw_text_face {
    float size, ascent, descent, baseline_fraction;
    uint16_t units_per_em;
    /// The one-line title's tracking, in font units, added after every glyph; its lines alone are kerned.
    int16_t tracking;
    uint32_t ink;
    /// Each Windows-1252 code's glyph; the box for one Geist lacks; DFW_NO_GLYPH for the soft hyphen.
    uint8_t glyph_of[256];
    /// The ligature glyphs for ff, fi, fl and tt.
    uint8_t ligature[4];
    uint8_t box;
    /// How many x phases: a glyph's x is snapped down to 1/phases of a pixel, and drawn with that phase's bitmap.
    uint8_t phases;
    const dfw_text_glyph *glyphs;
    const uint8_t *coverage;
    uint16_t kern_count;
    const dfw_kern *kerns;
};


"""

var widths = """
// Generated by tools/lc6000-display-fw/gen/text_font_gen.swift: CoreText's widths for lines as the renderer makes them,
// the C text measure's reference (#458). Do not edit.
typedef struct { const char *face; int tracked; const char *codes; double width; } text_width_case;
static const text_width_case text_width_cases[] = {

"""

let samples = ["Strobe", "AVATAR Tower", "Don’t", "Ænima", "Office fluff", "affluent officer", "fi\u{AD}x", "Café del Mar",
               "“Don’t” — Live…", "P.Y.T. (Pretty Young Thing)", "ffi", "tttt", "Ten (Original Mix)", "xxxxxxxxxxxxxxxxxxxx",
               "Tänzer Tübingen", "ß Þ Ø æ œ Œ", "Wolfgang Amadeus Mozart", "8A 128.0", "F#m —", "No track", "Load a track",
               "no title", "OSC clip", "Midiclip", "€ ™ ‰ † ‡ • –"]

func cString(_ codes: [UInt8]) -> String {
    "\"" + codes.map { String(format: "\\x%02X", $0) }.joined() + "\""
}

for face in faces {
    let font = loadFont(face.file, postScriptName: face.postScriptName, size: face.size)
    let upm = Int(CTFontGetUnitsPerEm(font))
    let unitFont = loadFont(face.file, postScriptName: face.postScriptName, size: CGFloat(upm))
    let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
    // Key and BPM sit in a "normal" line box, ascent + descent + leading; the C takes it as ascent + descent.
    guard face.middle >= 0 || CTFontGetLeading(font) == 0 else { fail("\(face.name): leading isn't 0") }
    let middle = face.middle >= 0 ? face.middle : 136 + (ascent + descent) / 2
    let baseline = middle + (ascent - descent) / 2
    let fraction = baseline - floor(baseline)
    let trackingUnits = face.tracking * CGFloat(upm)
    guard trackingUnits == trackingUnits.rounded() else { fail("\(face.name): tracking isn't whole font units") }

    // The glyphs: each code's, Geist's .notdef for the box, and the ligatures.
    var ids: [CGGlyph] = [0]
    var glyphOf = [Int](repeating: 0, count: 256)
    func index(_ id: CGGlyph) -> Int {
        if let i = ids.firstIndex(of: id) { return i }
        ids.append(id)
        return ids.count - 1
    }
    for code in 0x20...0xFF where code != 0x7F && !undefined.contains(code) {
        if code == softHyphen { glyphOf[code] = 255; continue }
        let chars = Array(character(code)!.utf16)
        var glyph: [CGGlyph] = [0]
        if chars.count == 1 { CTFontGetGlyphsForCharacters(font, chars, &glyph, 1) }
        glyphOf[code] = index(glyph[0])
    }
    var ligatureIndex: [Int] = []
    for pair in ligatures {
        let found = glyphIDs(makeLine(pair, font: font, tracking: 0))
        if found.count == 1 { ligatureIndex.append(index(found[0])) } else if face.postScriptName.contains("Mono") {
            ligatureIndex.append(255)
        } else { fail("\(face.name): \(pair) is \(found.count) glyphs") }
    }
    guard ids.count < 255 else { fail("\(face.name): \(ids.count) glyphs") }

    // Advances in font units, from the font at its units-per-em size.
    var advances = [CGSize](repeating: .zero, count: ids.count)
    CTFontGetAdvancesForGlyphs(unitFont, .horizontal, ids, &advances, ids.count)
    let advanceUnits = advances.map { Int($0.width.rounded()) }
    for (i, a) in advances.enumerated() where abs(a.width - a.width.rounded()) > 0.001 {
        fail("\(face.name): glyph \(ids[i]) advances \(a.width) units, not whole")
    }

    // Kerning, for the kerned face only: every pair of its glyphs, measured as a two-glyph line's width less the
    // advances. A glyph's string is its code's character, or the ligature's pair.
    var strings: [Int: String] = [:]
    for code in 0x20...0xFF where glyphOf[code] != 255 && glyphOf[code] != 0 && strings[glyphOf[code]] == nil {
        strings[glyphOf[code]] = character(code)!
    }
    for (i, pair) in ligatures.enumerated() where ligatureIndex[i] != 255 { strings[ligatureIndex[i]] = pair }
    var kerns: [(Int, Int)] = []
    if face.kerned {
        let indexes = strings.keys.sorted()
        for left in indexes { for right in indexes {
            let joined = strings[left]! + strings[right]!
            let line = kernedLine(joined, font: unitFont)
            // Only where the pair stays these two glyphs: a ligature across the join is taken before kerning, so the
            // C never kerns that pair.
            guard glyphIDs(line) == [ids[left], ids[right]] else { continue }
            let k = width(line) - Double(advanceUnits[left] + advanceUnits[right])
            guard abs(k - k.rounded()) < 0.01 else { fail("\(face.name): kern \(joined.debugDescription) is \(k) units") }
            if Int(k.rounded()) != 0 { kerns.append(((left << 8) | right, Int(k.rounded()))) }
        } }
    }

    // Rasterizing: each glyph by id, in the face's own colors, at its baseline's fraction, at an x phase.
    func rasterize(_ id: CGGlyph, _ phase: CGFloat = 0) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: box * box * 4)
        guard let context = CGContext(data: &pixels, width: box, height: box, bitsPerComponent: 8, bytesPerRow: box * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("context") }
        context.translateBy(x: 0, y: CGFloat(box))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(color(face.ground))
        context.fill(CGRect(x: 0, y: 0, width: box, height: box))
        context.translateBy(x: CGFloat(pad) + phase, y: CGFloat(box - pad) + fraction)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(color(face.ink))
        var glyph = id
        var origin = CGPoint.zero
        CTFontDrawGlyphs(font, &glyph, &origin, 1, context)
        return pixels
    }
    var coverageBytes: [UInt8] = []
    var glyphRows: [String] = []
    let groundG = Double(face.ground >> 8 & 0xFF), inkG = Double(face.ink >> 8 & 0xFF)
    // The x snap, measured: where a glyph's image changes as its origin moves across a pixel in 1/96 steps.
    var steps: [Int] = []
    var probe: CGGlyph = 0
    var h: [UniChar] = [0x48]
    CTFontGetGlyphsForCharacters(font, &h, &probe, 1)
    var previous = rasterize(probe, 0)
    for i in 1..<96 {
        let next = rasterize(probe, CGFloat(i) / 96)
        if next != previous { steps.append(i) }
        previous = next
    }
    let phases = steps.count + 1
    guard phases <= 4, steps.enumerated().allSatisfy({ abs(Double($0.element) - Double(($0.offset + 1) * 96) / Double(phases)) < 1 })
    else { fail("\(face.name): x snaps at \(steps) / 96, not evenly") }
    for (i, id) in ids.enumerated() {
      var bitmaps: [String] = []
      for p in 0..<phases {
        let pixels = rasterize(id, CGFloat(p) / CGFloat(phases))
        var level = [UInt8](repeating: 0, count: box * box)
        for p in 0..<(box * box) {
            let c = (Double(pixels[p * 4 + 1]) - groundG) / (inkG - groundG)
            level[p] = UInt8(max(0, min(15, (c * 15).rounded())))
        }
        var minX = box, minY = box, maxX = -1, maxY = -1
        for y in 0..<box { for x in 0..<box where level[y * box + x] > 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        let offset = coverageBytes.count
        if maxX < 0 {
            bitmaps.append("{ 0, 0, 0, 0, \(offset)u }")
            continue
        }
        guard minX > 0, minY > 0, maxX < box - 1, maxY < box - 1 else { fail("\(face.name): glyph \(id) doesn't fit the box") }
        for y in minY...maxY {
            var x = minX
            while x <= maxX {
                let high = level[y * box + x], low = x + 1 <= maxX ? level[y * box + x + 1] : 0
                coverageBytes.append(high << 4 | low)
                x += 2
            }
        }
        bitmaps.append("{ \(minX - pad), \(box - pad - minY), \(maxX - minX + 1), \(maxY - minY + 1), \(offset)u }")
      }
      glyphRows.append("    { \(advanceUnits[i]), { " + bitmaps.joined(separator: ", ") + " } },")
    }

    header += "/// \(face.postScriptName) \(Int(face.size)): \(face.about).\n"
    header += "static const uint8_t \(face.name)_coverage[] = {\n"
    for start in stride(from: 0, to: coverageBytes.count, by: 24) {
        header += "    " + coverageBytes[start..<min(start + 24, coverageBytes.count)].map { String(format: "0x%02X,", $0) }.joined() + "\n"
    }
    header += "};\nstatic const dfw_text_glyph \(face.name)_glyphs[] = {\n" + glyphRows.joined(separator: "\n") + "\n};\n"
    if !kerns.isEmpty {
        header += "static const dfw_kern \(face.name)_kerns[] = {\n"
        for start in stride(from: 0, to: kerns.count, by: 8) {
            header += "    " + kerns[start..<min(start + 8, kerns.count)].map { "{ 0x\(String(format: "%04X", $0.0)), \($0.1) }," }.joined(separator: " ") + "\n"
        }
        header += "};\n"
    }
    header += "static const dfw_text_face \(face.name)_face = {\n"
    header += "    \(face.size)f, \(ascent)f, \(descent)f, \(fraction)f, \(upm), \(Int(trackingUnits)), 0x\(String(format: "%06X", face.ink))u,\n"
    header += "    { " + glyphOf.map { String($0) }.joined(separator: ", ") + " },\n"
    header += "    { " + ligatureIndex.map { String($0) }.joined(separator: ", ") + " }, 0, \(phases), \(face.name)_glyphs, \(face.name)_coverage, \(kerns.count), "
    header += kerns.isEmpty ? "0,\n};\n\n" : "\(face.name)_kerns,\n};\n\n"

    // The width oracle: the samples as the renderer lays them out in this face.
    for sample in samples {
        guard let data = sample.data(using: .windowsCP1252) else { fail("\(sample) isn't Windows-1252") }
        for tracking in face.tracking == 0 ? [0] : [0, face.tracking] {
            widths += "    { \"\(face.name)\", \(tracking == 0 ? 0 : 1), \(cString(Array(data))), "
            widths += "\(width(makeLine(sample, font: font, tracking: tracking))) },\n"
        }
    }
}
header += "#endif\n"
widths += "};\n"
do {
    try header.write(toFile: arguments[0], atomically: true, encoding: .utf8)
    try widths.write(toFile: arguments[1], atomically: true, encoding: .utf8)
} catch { fail("Can't write: \(error)") }
