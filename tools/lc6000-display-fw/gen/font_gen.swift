// Rasterizes the Geist faces the header uses into 8-bit coverage for the drawn display firmware (#457), with CoreText,
// the way JogDisplayRenderer draws them, so the C glyphs match the Swift reference. Writes src/font_header.h:
//   swift tools/lc6000-display-fw/gen/font_gen.swift > tools/lc6000-display-fw/src/font_header.h
// Run from the repo root. Fonts: Packages/ControllerBridgeKit/Sources/ControllerBridgeRender/Fonts (SIL OFL 1.1).
//
// What CoreText does here, measured, and copied:
// - A glyph's x origin is snapped down to a fraction of a pixel that depends on the face and size (halves for
//   Geist-Bold 18, thirds for GeistMono-SemiBold 14), so each glyph is kept at every one of those x phases. The
//   generator measures the fraction and fails if the steps aren't even.
// - Its y origin is not snapped, so each face is rasterized at the one baseline the header uses (fixed by the layout).
// - Light text on dark is drawn heavier than dark on light, so each face is rasterized in the colors it is drawn in;
//   the coverage of dark text was measured to be the same on any ground.
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

func loadFont(_ file: String, postScriptName: String, size: CGFloat) -> CTFont {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: "\(fontDir)/\(file)") as CFURL)
            as? [CTFontDescriptor], let descriptor = descriptors.first else { fail("Can't read \(fontDir)/\(file)") }
    let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    // Never a silent fallback to another face.
    guard CTFontCopyPostScriptName(font) as String == postScriptName else { fail("\(file) is not \(postScriptName)") }
    return font
}

func color(_ hex: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

func makeLine(_ string: String, font: CTFont, color: CGColor, tracking: CGFloat) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        kCTKernAttributeName as NSAttributedString.Key: tracking * CTFontGetSize(font),
    ]))
}

struct Face {
    let name: String, file: String, postScriptName: String, size: CGFloat
    let ink: Int, ground: Int
    /// Where the layout puts the line's middle: the baseline is this + (ascent − descent) / 2.
    let middle: CGFloat
    let tracking: CGFloat
    let glyphs: String
    /// Strings the layout draws, checked to be laid out as the advances plus tracking say.
    let lines: [String]
    /// The channel coverage is read from (0 red, 1 green, 2 blue): the one where ink and ground are furthest apart.
    var channel = 1
}

let faces = [
    // The deck number: Geist-Bold 18 in the ground color on the chip, centered at y 37.
    Face(name: "number", file: "Geist-Bold.ttf", postScriptName: "Geist-Bold", size: 18, ink: 0x0B0B0B, ground: 0xFFFFFF,
         middle: 37, tracking: 0, glyphs: "1234", lines: ["1", "2", "3", "4"]),
    // The same number in the text white on a dark deck color (#542 follow-up, DeckNumberInk): light text is drawn
    // heavier, so it has its own coverage. Rasterized on the ground: on purple or navy it comes out the same.
    Face(name: "number_white", file: "Geist-Bold.ttf", postScriptName: "Geist-Bold", size: 18, ink: 0xEDEDEA,
         ground: 0x0B0B0B, middle: 37, tracking: 0, glyphs: "1234", lines: ["1", "2", "3", "4"]),
    // The player badge: GeistMono-SemiBold 14 in 0xEDEDEA on the ground, tracked 0.04 em, centered at y 37.5.
    Face(name: "badge", file: "GeistMono-SemiBold.ttf", postScriptName: "GeistMono-SemiBold", size: 14, ink: 0xEDEDEA,
         ground: 0x0B0B0B, middle: 37.5, tracking: 0.04, glyphs: "CDEIKMOQRST", lines: ["TRK", "OSC", "MIDI", "SEQ"]),
    // The time left (#460, #524): drawn mode's GeistMono-SemiBold 21 in 0xEDEDEA on the ground, untracked, centered
    // at y 160.
    Face(name: "time", file: "GeistMono-SemiBold.ttf", postScriptName: "GeistMono-SemiBold", size: layout("timeSize"),
         ink: layoutColor("text"), ground: layoutColor("ground"), middle: layout("timeCenterY"), tracking: 0, glyphs: "-0123456789:", lines: ["-2:45", "-1:22", "-99:59", "-0:00"]),
    // The same in the last minute's warning red, 0xFF3B30 (#460): light text is drawn heavier, so red has its own
    // coverage, read from the red channel (its green is only 48 levels off the ground).
    Face(name: "time_red", file: "GeistMono-SemiBold.ttf", postScriptName: "GeistMono-SemiBold", size: layout("timeSize"),
         ink: layoutColor("warningRed"), ground: layoutColor("ground"), middle: layout("timeCenterY"), tracking: 0, glyphs: "-0123456789:", lines: ["-0:30", "-0:59"], channel: 0),
]

let pad = 16, box = 48
var out = """
// Generated by tools/lc6000-display-fw/gen/font_gen.swift from the Geist fonts (SIL OFL 1.1,
// Packages/ControllerBridgeKit/Sources/ControllerBridgeRender/Fonts/Geist-OFL.txt). Do not edit. Regenerate from the repo root:
//   swift tools/lc6000-display-fw/gen/font_gen.swift > tools/lc6000-display-fw/src/font_header.h
// 8-bit coverage per glyph at each x phase CoreText uses (it snaps a glyph's x down to 1/phases of a pixel), rasterized
// at the baseline the header draws each face at. `left` and `top` place the bitmap from the glyph origin, rounded down.
#ifndef DFW_FONT_HEADER_H
#define DFW_FONT_HEADER_H
#include <stdint.h>

typedef struct { int8_t left, top; uint8_t width, height; const uint8_t *coverage; } dfw_glyph_bitmap;
#define DFW_PHASES_MAX 4
typedef struct { char code; float advance; dfw_glyph_bitmap phase[DFW_PHASES_MAX]; } dfw_glyph;
typedef struct {
    float ascent, descent, tracking, baseline_fraction;
    uint32_t ink;
    uint8_t phases, count;
    const dfw_glyph *glyphs;
} dfw_face;


"""

for face in faces {
    let font = loadFont(face.file, postScriptName: face.postScriptName, size: face.size)
    let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
    let baseline = face.middle + (ascent - descent) / 2
    let fraction = baseline - floor(baseline)
    let kern = face.tracking * face.size

    // The layout's sums must equal CoreText's line: each glyph advances by its advance plus the tracking, trailing too.
    var advances: [Character: CGFloat] = [:]
    for ch in face.glyphs {
        let line = makeLine(String(ch), font: font, color: color(face.ink), tracking: 0)
        advances[ch] = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
    for string in face.lines {
        let line = makeLine(string, font: font, color: color(face.ink), tracking: face.tracking)
        var x: CGFloat = 0
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        guard runs.count == 1 else { fail("\(string): \(runs.count) runs") }
        var positions = [CGPoint](repeating: .zero, count: CTRunGetGlyphCount(runs[0]))
        CTRunGetPositions(runs[0], CFRange(location: 0, length: 0), &positions)
        for (i, ch) in string.enumerated() {
            guard abs(positions[i].x - x) < 0.001, positions[i].y == 0 else { fail("\(string)[\(i)] at \(positions[i]), not \(x)") }
            x += advances[ch]! + kern
        }
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard abs(width - x) < 0.001 else { fail("\(string) is \(width) wide, not \(x)") }
    }

    func rasterize(_ ch: Character, _ phase: CGFloat) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: box * box * 4)
        guard let context = CGContext(data: &pixels, width: box, height: box, bitsPerComponent: 8, bytesPerRow: box * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("context") }
        // As JogDisplayRenderer draws: y down, then CoreText flipped around the baseline.
        context.translateBy(x: 0, y: CGFloat(box))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(color(face.ground))
        context.fill(CGRect(x: 0, y: 0, width: box, height: box))
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: CGFloat(pad) + phase, y: CGFloat(pad) + fraction)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(makeLine(String(ch), font: font, color: color(face.ink), tracking: 0), context)
        context.restoreGState()
        return pixels
    }
    // The x snap, measured: where the image changes as the origin moves across a pixel in 1/96 steps.
    var steps: [Int] = []
    let probe = face.glyphs.first!
    var previous = rasterize(probe, 0)
    for i in 1..<96 {
        let next = rasterize(probe, CGFloat(i) / 96)
        if next != previous { steps.append(i) }
        previous = next
    }
    let phaseCount = steps.count + 1
    guard phaseCount <= 4, steps.enumerated().allSatisfy({ abs(Double($0.element) - Double(($0.offset + 1) * 96) / Double(phaseCount)) < 1 })
    else { fail("\(face.name): x snaps at \(steps) / 96, not evenly") }

    var table = "static const dfw_glyph \(face.name)_glyphs[] = {\n"
    for ch in face.glyphs {
        var phases: [String] = []
        for p in 0..<phaseCount {
            let pixels = rasterize(ch, CGFloat(p) / CGFloat(phaseCount))
            // Coverage from the face's channel: how far each pixel moved from the ground toward the ink.
            let shift = (2 - face.channel) * 8
            let ground = Double(face.ground >> shift & 0xFF), ink = Double(face.ink >> shift & 0xFF)
            var coverage = [UInt8](repeating: 0, count: box * box)
            for i in 0..<(box * box) {
                let c = (Double(pixels[i * 4 + face.channel]) - ground) / (ink - ground)
                coverage[i] = UInt8(max(0, min(255, (c * 255).rounded())))
            }
            var minX = box, minY = box, maxX = -1, maxY = -1
            for y in 0..<box { for x in 0..<box where coverage[y * box + x] > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            guard maxX >= 0, minX > 0, minY > 0, maxX < box - 1, maxY < box - 1 else { fail("\(ch) doesn't fit the box") }
            // A letter or digit names its bitmap; anything else ('-', ':') by its code, to make a C name.
            let tag = ch.isLetter || ch.isNumber ? String(ch) : String(format: "x%02X", ch.asciiValue!)
            let symbol = "\(face.name)_\(tag)_\(p)"
            var bytes: [String] = []
            for y in minY...maxY { bytes.append((minX...maxX).map { String(format: "%3d", coverage[y * box + $0]) }.joined(separator: ",")) }
            out += "static const uint8_t \(symbol)[] = {\n    " + bytes.joined(separator: ",\n    ") + ",\n};\n"
            phases.append("{ \(minX - pad), \(minY - pad), \(maxX - minX + 1), \(maxY - minY + 1), \(symbol) }")
        }
        table += "    { '\(ch)', \(advances[ch]!)f, { \(phases.joined(separator: ", ")) } },\n"
    }
    table += "};\n"
    out += table
    out += """
    /// \(face.postScriptName) \(Int(face.size)), drawn at baselines \(fraction) past a whole pixel (middle \(face.middle)),
    /// its x snapped down to 1/\(phaseCount) px.
    static const dfw_face \(face.name)_face = {
        \(ascent)f, \(descent)f, \(kern)f, \(fraction)f, 0x\(String(format: "%06X", face.ink))u, \(phaseCount), \(face.glyphs.count), \(face.name)_glyphs,
    };


    """
}
out += "#endif\n"
print(out, terminator: "")
