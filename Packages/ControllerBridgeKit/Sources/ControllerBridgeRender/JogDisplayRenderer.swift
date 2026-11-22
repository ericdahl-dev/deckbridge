// The LC6000 jog display's image (#165): 198×198, round, upright, in the chosen design B, "track first". From the top:
// the deck as a chip in its color and a player badge; the title (the biggest text, one line, or two split at a word);
// the artist; a rule in the deck color; key and BPM. Around the edge, the master clock's four beat sections. A value
// Syndicate didn't send shows "—", never a made-up one. Every line is cut with an ellipsis to the round screen, never
// shrunk: nothing is under 14 px. The layout is the designer's (gen.py), in its pixels.
//
// A pure function, shared by the upload and the Diagnostics simulator (#221). The upload draws no lit beat and no
// needle: the needle is the unit's own (pitch bend), and a lit beat would need an upload per beat. The simulator can
// pass both to show what the unit would.
import ControllerBridgeCore
import CoreGraphics
import CoreText
import Foundation

public enum JogDisplayRenderer {
    public static let size = JogImage.size

    /// RGBA bytes, row by row, top first, upright: what `JogImage.forUnit` turns and encodes. `litBeat` (1–4) lights
    /// that beat's section; `needle` draws the needle that many turns clockwise from 12 o'clock.
    /// `phase` is the deck's offset from the master's beat in 1/16384 beats (#462), as op 0B carries it; nil is unknown.
    public static func render(_ content: JogDisplayContent, litBeat: Int? = nil, needle: Double? = nil,
                              meter: (level: Int, peak: Int)? = nil, phase: Int? = nil,
                              time: (elapsed: Int, length: Int)? = nil, look: JogTrackTime.Look = .normal) -> [UInt8] {
        drawing { context in
            frame(content, litBeat: litBeat, needle: needle, meter: meter, phase: phase, time: time, look: look,
                  drawn: false, in: context)
        }
    }

    /// The drawn display as the panel shows it (#524): 216×216 RGBA, the 198 frame centered (9 px in) on the panel's
    /// black, so the band just outside the frame shows too. Drawn mode only; image mode keeps `simulatorImage`.
    public static let drawnSize = 216
    public static func drawnImage(_ content: JogDisplayContent, live: DrawnLive) -> [UInt8] {
        let inset = CGFloat(drawnSize - size) / 2
        return drawing(size: drawnSize) { context in
            context.setFillColor(rgb(0x000000))
            context.fill(CGRect(x: 0, y: 0, width: drawnSize, height: drawnSize))
            context.translateBy(x: inset, y: inset)
            frame(content, litBeat: live.beat, needle: live.needle.map { Double($0) / 16384 },
                  meter: live.meter.map { ($0.level, $0.peak) }, phase: live.phase,
                  time: live.time.map { ($0.elapsed, $0.length) }, look: live.look, drawn: true, in: context)
            // The band outside the frame (#524): the progress ring, in the frame's coordinates.
            if let time = live.time, time.length > 0, !content.stale {
                drawRing(elapsed: time.elapsed, length: time.length, look: live.look, deck: content.color, in: context)
            }
        }
    }

    /// The 198 frame and its live parts, in the frame's own coordinates.
    private static func frame(_ content: JogDisplayContent, litBeat: Int?, needle: Double?, meter: (level: Int, peak: Int)?,
                              phase: Int?, time: (elapsed: Int, length: Int)?, look: JogTrackTime.Look,
                              drawn: Bool, in context: CGContext) {
        let layout = drawn ? Layout.drawn : Layout.image
        draw(content, litBeat: litBeat, phase: phase, layout: layout, in: context)
        if let meter, !content.stale { drawMeter(level: meter.level, peak: meter.peak, in: context) }
        if let time, time.length > 0, !content.stale {
            drawTime(elapsed: time.elapsed, length: time.length, look: look, deck: content.color, layout: layout,
                     in: context)
        }
        if let needle { drawNeedle(turns: needle, in: context) }
    }

    /// RGBA rows of a `size`×`size` image, drawn with a top-left origin and y down, as the rows are stored and the
    /// design measures.
    private static func drawing(size: Int = size, _ body: (CGContext) -> Void) -> [UInt8] {
        _ = fontsRegistered
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return pixels }
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        body(context)
        return pixels
    }

    // MARK: The design's measurements

    // The numbers shared with the chip's C come from JogLayout (layout/layout.json, #571).
    static let center = CGFloat(JogLayout.center)
    static let ringOuter = CGFloat(JogLayout.ringOuter), ringInner = CGFloat(JogLayout.ringInner)
    /// The gap between beat sections, measured at mid-band.
    static let ringGap = CGFloat(JogLayout.ringGap)
    /// Text stays inside this circle, 6 px clear of the ring.
    static let safe: CGFloat = 79

    static let background = rgb(JogLayout.ground), text = rgb(JogLayout.text), caption = rgb(JogLayout.caption)
    static let keyColor = rgb(JogLayout.keyInk)
    static let live = rgb(JogLayout.live), beatOff = rgb(JogLayout.beatOff), downbeatOff = rgb(JogLayout.downbeatOff)
    /// The deck number's ink on its color: black, or white on a dark one (DeckNumberInk).
    private static func numberInk(_ deck: [Int]) -> CGColor { DeckNumberInk.white(on: deck) ? text : background }

    /// The level meter (#461): an arc just inside the ring on the left, from 240° (bottom) to 300° clockwise from
    /// 12 o'clock. Green to `meterYellowFrom` of the arc, yellow above; the whole fill red at clip (127).
    static let meterInner = CGFloat(JogLayout.meterInner), meterOuter = CGFloat(JogLayout.meterOuter)
    static let meterFrom: CGFloat = 240, meterSpan: CGFloat = 60, meterYellowFrom: CGFloat = 0.75
    /// Track time (#460): the remaining time's size and the middle of its line box, under key/BPM. The largest that
    /// keeps "-99:59" inside the text-safe circle with a gap under key/BPM; the user asked for about 18, which reaches r 83.
    /// Where the foot's lines go: image mode's design B (key/BPM 22 px, its line box from y 136) or drawn mode's
    /// (#524, the user's pick): key/BPM 18 px and the remaining time 21 px, both whole inside the text-safe circle with
    /// "12A 174.0" and "-99:59", their ink from y 134 (5 px under the rule) and 5 px apart.
    struct Layout {
        let keySize: CGFloat, keyCenterY: CGFloat?, timeSize: CGFloat, timeCenterY: CGFloat
        static let image = Layout(keySize: 22, keyCenterY: nil, timeSize: 14, timeCenterY: 169)
        static let drawn = Layout(keySize: CGFloat(JogLayout.keySize), keyCenterY: CGFloat(JogLayout.keyCenterY),
                                  timeSize: CGFloat(JogLayout.timeSize), timeCenterY: CGFloat(JogLayout.timeCenterY))
    }
    /// The progress ring (#524), in the panel's black band outside the frame: r 103–107 from the frame's center, a
    /// 0x4A4A4A track. How much of the band the round window shows is checked on the unit (#469).
    static let progressInner = CGFloat(JogLayout.bandInner), progressOuter = CGFloat(JogLayout.bandOuter)
    static let progressTrack = rgb(JogLayout.bandTrack)
    /// The peak tick's width, in degrees.
    static let meterTick: CGFloat = 2
    static let meterYellow = rgb(JogLayout.meterYellow), meterClip = rgb(JogLayout.warningRed)
    static let meterPeak = rgb(JogLayout.meterPeak)

    static func badge(_ playerType: String?) -> String? { JogDisplayWords.badge(playerType) }
    static func untitled(_ playerType: String?) -> (title: String, caption: String) { JogDisplayWords.untitled(playerType) }

    // MARK: Drawing

    /// The image the jog display upload sends (#165), before `JogImage.forUnit` turns it: no lit beat and no needle,
    /// which are the unit's own.
    public static func uploadImage(_ content: JogDisplayContent) -> [UInt8] { render(content) }

    /// One beat slot's image (#215): the upload's with master beat `litBeat` (1–4) lit. The unit holds all four and
    /// shows one per beat; the needle stays the unit's own.
    public static func uploadImage(_ content: JogDisplayContent, litBeat: Int) -> [UInt8] { render(content, litBeat: litBeat) }

    /// The image the Diagnostics simulator shows (#221): the upload's, with the lit beat and the needle the unit would
    /// draw over it. With neither, it is the upload's exactly (a test pins it).
    /// `meter` is the front deck's mixer level and held peak, 0–127 each (#461), as the drawn display shows them.
    /// `phase` is the deck's offset from the master's beat (#462), in 1/16384 beats as op 0B carries it; nil is unknown.
    public static func simulatorImage(_ content: JogDisplayContent, litBeat: Int?, needle: Double?,
                                      meter: (level: Int, peak: Int)? = nil, phase: Int? = nil,
                                      time: (elapsed: Int, length: Int)? = nil, look: JogTrackTime.Look = .normal) -> [UInt8] {
        render(content, litBeat: litBeat, needle: needle, meter: meter, phase: phase, time: time, look: look)
    }

    /// The Geist faces the design uses, bundled with this target (#221) so the image is the same in the app and under
    /// `swift test`: unregistered, CoreText would quietly draw another font. Registered once, for this process.
    static let fontNames = ["Geist-Bold", "Geist-Medium", "GeistMono-SemiBold"]
    static let fontsRegistered: Void = {
        let urls = fontNames.compactMap { Bundle.module.url(forResource: $0, withExtension: "ttf", subdirectory: "Fonts") }
        // Already registered (the app registers its own copies) is fine: the same faces either way.
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }()

    private static func draw(_ content: JogDisplayContent, litBeat: Int?, phase: Int?, layout: Layout, in context: CGContext) {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: 198, height: 198))
        if content.stale {
            // The waiting look (#464): the beat ring dark, our logo in the middle.
            ring(litBeat: nil, allDark: true, in: context)
            // #524, the user's pick: the deck in the logo's hub, in its color with its number in black. The deck layer
            // is the controller's own and can change while Syndicate is silent.
            JogLogo.draw(in: context, center: CGPoint(x: center, y: center), scale: JogLogo.scale, hub: color(content.color))
            let number = CTFontCreateWithName("Geist-Bold" as CFString, 18, nil)
            draw(makeLine("\(content.deck)", font: number, color: numberInk(content.color)), font: number, centerX: center,
                 centerY: center, in: context)
            return
        }
        ring(litBeat: litBeat, in: context)
        let deckColor = color(content.color)
        header(deck: content.deck, color: deckColor, ink: numberInk(content.color), badge: badge(content.playerType),
               in: context)

        let block = textBlock(content)
        for text in block.lines { line(text, in: context) }
        rule(phase: phase, color: deckColor, in: context)
        if block.foot { keyAndBPM(key: content.key, bpm: content.bpm, layout: layout, in: context) }
    }

    /// The rule in the deck color (#462). Unknown phase: the plain rule. In phase: the rule with a 2×6 tick at its
    /// center. Off phase: the rule dimmed to `phaseDim` of the deck color over the ground, and a 4 px bar in the deck
    /// color from the center, left for behind and right for ahead, `phaseBar` px long.
    private static func rule(phase: Int?, color: CGColor, in context: CGContext) {
        guard let phase, phase != 0 else {
            context.setFillColor(color)
            context.fill(ruleRect)
            if phase == 0 { context.fill(tickRect) }
            return
        }
        context.setFillColor(dimmed(color))
        context.fill(ruleRect)
        let length = CGFloat(phaseBar(phase))
        context.setFillColor(color)
        context.fill(CGRect(x: phase < 0 ? center - length : center, y: CGFloat(JogLayout.barY), width: length,
                            height: CGFloat(JogLayout.barHeight)))
    }

    /// The rule, and the in-phase tick at its center (JogLayout, shared with the chip).
    static let ruleRect = CGRect(x: CGFloat(JogLayout.ruleX), y: CGFloat(JogLayout.ruleY), width: CGFloat(JogLayout.ruleWidth),
                                 height: CGFloat(JogLayout.ruleHeight))
    static let tickRect = CGRect(x: CGFloat(JogLayout.tickX), y: CGFloat(JogLayout.tickY), width: CGFloat(JogLayout.tickWidth),
                                 height: CGFloat(JogLayout.tickHeight))

    /// How much of the deck color the rule keeps while off phase.
    static let phaseDim = CGFloat(JogLayout.phaseDim)
    /// The ground's level in each channel (it is a gray).
    static let groundLevel = CGFloat(JogLayout.ground & 0xFF)

    /// The deck color at `phaseDim` over the ground, each channel rounded to a whole 0–255 level.
    private static func dimmed(_ color: CGColor) -> CGColor {
        let deck = color.components ?? [1, 1, 1, 1]
        let level = { (channel: CGFloat) -> CGFloat in ((channel * 255 * phaseDim + groundLevel * (1 - phaseDim)).rounded()) / 255 }
        return CGColor(srgbRed: level(deck[0]), green: level(deck[1]), blue: level(deck[2]), alpha: 1)
    }

    /// The phase bar's length in whole px (#462): 49 (the half rule) × g(p)/g(½), g(p) = p/(|p| + 0.02), for p the
    /// offset in beats (`phase`/16384); so a hundredth of a beat is a third of the way and half a beat the whole half.
    /// At least 1 px off phase.
    static func phaseBar(_ phase: Int) -> Int {
        func g(_ beats: Double) -> Double { beats / (abs(beats) + JogLayout.phaseCurve) }
        let most = JogLayout.barMax
        let length = (Double(most) * g(abs(Double(phase)) / Double(JogLayout.phaseUnitsPerBeat)) / g(JogLayout.phaseFull)).rounded()
        return max(1, min(most, Int(length)))
    }

    /// One line of the text block: its words, face, CSS line box and tracking. The drawn display firmware lays out the
    /// same block (#458; test/ref/text_layout.h is this, checked by DisplayFirmwareTextLayoutTests).
    struct TextLine {
        let string: String, font: String, size: CGFloat, lineHeight: CGFloat, top: CGFloat, color: CGColor
        var tracking: CGFloat = 0
    }

    /// The text block between the header and the rule: the title (or an untitled deck's words) and the artist (or its
    /// caption); and whether key and BPM show below the rule.
    static func textBlock(_ content: JogDisplayContent) -> (lines: [TextLine], foot: Bool) {
        let title = content.title ?? ""
        if title.isEmpty {
            // No title: the deck says what it holds, or that it's empty. Nothing invented.
            let words = untitled(content.playerType)
            return ([TextLine(string: words.title, font: "Geist-Bold", size: 26, lineHeight: 1.1, top: CGFloat(JogLayout.untitledTop), color: text),
                     TextLine(string: words.caption, font: "Geist-Medium", size: 16, lineHeight: 1.1, top: CGFloat(JogLayout.untitledCaptionTop),
                                     color: caption)],
                    badge(content.playerType) != nil && badge(content.playerType) != "TRK")
        }
        var lines: [TextLine]
        let artistTop: CGFloat
        if titleSize(title) == 26 {
            lines = [TextLine(string: title, font: "Geist-Bold", size: 26, lineHeight: 1.15, top: 60, color: text, tracking: -0.01)]
            artistTop = 94
        } else {
            // Wrapped at words; titleLines already fits both lines, so only line 2 can end in an ellipsis.
            let wrapped = titleLines(title)
            if wrapped.count > 1 {
                lines = [TextLine(string: wrapped[0], font: "Geist-Bold", size: twoLineSize, lineHeight: 1.1, top: 54, color: text),
                         TextLine(string: wrapped[1], font: "Geist-Bold", size: twoLineSize, lineHeight: 1.1, top: 78, color: text)]
                artistTop = 103
            } else {
                // One line at 20 px: centered where the 26 px line sits (box center 75), the artist where it goes then.
                lines = [TextLine(string: wrapped[0], font: "Geist-Bold", size: twoLineSize, lineHeight: 1.1,
                                  top: 75 - twoLineSize * 1.1 / 2, color: text)]
                artistTop = 94
            }
        }
        lines.append(TextLine(string: content.artist.flatMap { $0.isEmpty ? nil : $0 } ?? "—", font: "Geist-Medium", size: 16,
                              lineHeight: 1.15, top: artistTop, color: caption))
        return (lines, true)
    }

    /// The four beat sections, clockwise from 12 o'clock; beat 1 a step brighter when unlit.
    private static func ring(litBeat: Int?, allDark: Bool = false, in context: CGContext) {
        let half = (ringGap / ((ringOuter + ringInner) / 2)) / 2
        for beat in 0..<4 {
            let start = CGFloat(beat) * .pi / 2 + half, end = CGFloat(beat + 1) * .pi / 2 - half
            let path = CGMutablePath()
            // Angles from 12 o'clock clockwise; on screen (y down) that's CoreGraphics angle − π/2, growing clockwise.
            path.addArc(center: CGPoint(x: center, y: center), radius: ringOuter, startAngle: start - .pi / 2,
                        endAngle: end - .pi / 2, clockwise: false)
            path.addArc(center: CGPoint(x: center, y: center), radius: ringInner, startAngle: end - .pi / 2,
                        endAngle: start - .pi / 2, clockwise: true)
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(litBeat == beat + 1 ? live : beat == 0 && !allDark ? downbeatOff : beatOff)
            context.fillPath()
        }
    }

    /// The deck chip (a 26 px circle in the deck color, its number in black) and the player badge, centered at y 37.
    private static func header(deck: Int, color deckColor: CGColor, ink: CGColor, badge label: String?,
                               in context: CGContext) {
        let chip: CGFloat = 26, gap: CGFloat = 6, mid: CGFloat = 37
        let badgeFont = CTFontCreateWithName("GeistMono-SemiBold" as CFString, 14, nil)
        let badgeLine = label.map { makeLine($0, font: badgeFont, color: text, tracking: 0.04) }
        let badgeWidth = badgeLine.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) + 12 + 3 } ?? 0
        let total = chip + (badgeLine == nil ? 0 : gap + badgeWidth)
        let left = center - total / 2
        context.setFillColor(deckColor)
        context.fillEllipse(in: CGRect(x: left, y: mid - chip / 2, width: chip, height: chip))
        let number = CTFontCreateWithName("Geist-Bold" as CFString, 18, nil)
        draw(makeLine("\(deck)", font: number, color: ink), font: number, centerX: left + chip / 2, centerY: mid,
             in: context)
        guard let badgeLine else { return }
        // A 1.5 px outline, 5 px corners, 22 px tall.
        let box = CGRect(x: left + chip + gap, y: mid - 11, width: badgeWidth, height: 22).insetBy(dx: 0.75, dy: 0.75)
        context.setStrokeColor(caption)
        context.setLineWidth(1.5)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 4.25, cornerHeight: 4.25, transform: nil))
        context.strokePath()
        draw(badgeLine, font: badgeFont, centerX: box.midX, centerY: mid + 0.5, in: context)
    }

    /// Key in blue and BPM in white, monospaced, at y 136; "—" for either one Syndicate didn't send.
    private static func keyAndBPM(key: String?, bpm: Double?, layout: Layout, in context: CGContext) {
        let font = CTFontCreateWithName("GeistMono-SemiBold" as CFString, layout.keySize, nil)
        let keyText = key.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        let bpmText = bpm.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil } ?? "—"
        let string = NSMutableAttributedString(string: keyText + " " + bpmText, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: text,
        ])
        string.addAttribute(kCTForegroundColorAttributeName as NSAttributedString.Key, value: keyColor,
                            range: NSRange(location: 0, length: (keyText as NSString).length))
        // Not cut to the safe circle, as in the design: a key and a BPM are short, and both must show whole.
        let height = lineBoxHeight(font, lineHeight: nil)
        draw(CTLineCreateWithAttributedString(string), font: font, centerX: center,
             centerY: layout.keyCenterY ?? 136 + height / 2, in: context)
    }

    /// Track time (#460): the time left, "-m:ss" (minutes past 59 stay minutes), in the slot under key/BPM. Seconds.
    /// Around the edge, the progress ring: the deck color clockwise from 12 o'clock, the rest a dark track.
    /// The warning's color now: red, or white in the blink's other half; nil for none.
    private static func warningColor(_ look: JogTrackTime.Look) -> CGColor? {
        switch look {
        case .normal: nil
        case .warningRed: color(JogTrackTime.warningRed)
        case .warningWhite: color(JogTrackTime.warningWhite)
        }
    }

    /// The time left, "-m:ss", under key/BPM: white, or the warning's color.
    private static func drawTime(elapsed: Int, length: Int, look: JogTrackTime.Look, deck: [Int], layout: Layout,
                                 in context: CGContext) {
        let left = length - min(max(elapsed, 0), length)
        let font = CTFontCreateWithName("GeistMono-SemiBold" as CFString, layout.timeSize, nil)
        draw(makeLine(String(format: "-%d:%02d", left / 60, left % 60), font: font, color: warningColor(look) ?? text),
             font: font, centerX: center, centerY: layout.timeCenterY, in: context)
    }

    /// The progress ring in the band outside the frame (#524): the track all round, the fill clockwise from 12 in the
    /// deck color or the warning's.
    private static func drawRing(elapsed: Int, length: Int, look: JogTrackTime.Look, deck: [Int], in context: CGContext) {
        let elapsed = min(max(elapsed, 0), length)
        band(inner: progressInner, outer: progressOuter, from: 0, to: 360, color: progressTrack, in: context)
        band(inner: progressInner, outer: progressOuter, from: 0, to: 360 * CGFloat(elapsed) / CGFloat(length),
             color: warningColor(look) ?? color(deck), in: context)
    }

    /// The level meter (#461): the dark track, the fill from the bottom, the held peak as a tick. Levels 0–127.
    private static func drawMeter(level: Int, peak: Int, in context: CGContext) {
        let level = min(max(level, 0), 127), peak = min(max(peak, 0), 127)
        meterArc(from: 0, to: 1, color: beatOff, in: context)
        let fill = CGFloat(level) / 127
        if level == 127 {
            meterArc(from: 0, to: 1, color: meterClip, in: context)
        } else if level > 0 {
            meterArc(from: 0, to: min(fill, meterYellowFrom), color: live, in: context)
            if fill > meterYellowFrom { meterArc(from: meterYellowFrom, to: fill, color: meterYellow, in: context) }
        }
        guard peak > 0 else { return }
        // The tick's degrees, kept inside the arc.
        let half = meterTick / 2 / meterSpan
        let place = min(max(CGFloat(peak) / 127, half), 1 - half)
        meterArc(from: place - half, to: place + half, color: peak == 127 ? meterClip : meterPeak, in: context)
    }

    /// The meter band between fractions `from` and `to` of the arc (0 its bottom), filled in `color`.
    private static func meterArc(from: CGFloat, to: CGFloat, color: CGColor, in context: CGContext) {
        band(inner: meterInner, outer: meterOuter, from: meterFrom + meterSpan * from, to: meterFrom + meterSpan * to,
             color: color, in: context)
    }

    /// The band between radii `inner` and `outer`, from `from` to `to` degrees clockwise from 12 o'clock, in `color`.
    private static func band(inner: CGFloat, outer: CGFloat, from: CGFloat, to: CGFloat, color: CGColor,
                             in context: CGContext) {
        guard to > from else { return }
        // On screen (y down) that's CoreGraphics angle − 90°, growing clockwise.
        let start = (from - 90) * .pi / 180, end = (to - 90) * .pi / 180
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: center, y: center), radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: CGPoint(x: center, y: center), radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }

    /// The needle: a white wedge with a black keyline riding the ring's edge, pointing in.
    private static func drawNeedle(turns: Double, in context: CGContext) {
        let degrees = turns.truncatingRemainder(dividingBy: 1) * 360
        func point(_ radius: CGFloat, _ deg: Double) -> CGPoint {
            let a: Double = deg * Double.pi / 180
            let x: CGFloat = center + radius * CGFloat(sin(a))
            let y: CGFloat = center - radius * CGFloat(cos(a))
            return CGPoint(x: x, y: y)
        }
        let path = CGMutablePath()
        path.addLines(between: [point(ringInner - 6, degrees), point(98.5, degrees - 4.2), point(98.5, degrees + 4.2)])
        path.closeSubpath()
        context.setLineJoin(.round)
        context.setLineWidth(2)
        context.setStrokeColor(rgb(0x000000))
        context.addPath(path)
        context.strokePath()
        context.setFillColor(rgb(0xFFFFFF))
        context.addPath(path)
        context.fillPath()
    }

    // MARK: Text

    /// The title's size: 26 px on one line when it fits there whole, else 20 px wrapped (#165 follow-up). Measured in
    /// Geist itself: before registration CoreText would hand back (and keep) a fallback.
    static func titleSize(_ title: String) -> CGFloat {
        _ = fontsRegistered
        let font = CTFontCreateWithName("Geist-Bold" as CFString, 26, nil)
        let line = makeLine(title, font: font, color: text, tracking: -0.01)
        let room = chord(top: 60, height: lineBoxHeight(font, lineHeight: 1.15))
        return CTLineGetTypographicBounds(line, nil, nil, nil) <= room ? 26 : twoLineSize
    }

    /// The title as drawn: one line when it fits at 26 px (as the design); else at 20 px,
    /// wrapped at words. Line 1 takes the whole words that fit its width on the round screen (a first word too long for
    /// it is broken there); line 2 takes the rest, and only line 2 ends in an ellipsis when the rest doesn't fit.
    static func titleLines(_ title: String) -> [String] {
        guard titleSize(title) == twoLineSize else { return [title] }
        _ = fontsRegistered
        let font = CTFontCreateWithName("Geist-Bold" as CFString, twoLineSize, nil)
        let height = lineBoxHeight(font, lineHeight: 1.1)
        let first = chord(top: 54, height: height), second = chord(top: 78, height: height)
        func fits(_ text: String, _ width: CGFloat) -> Bool {
            CTLineGetTypographicBounds(makeLine(text, font: font, color: Self.text), nil, nil, nil) <= width
        }
        let words = title.split(separator: " ").map(String.init)
        var count = 0
        while count < words.count, fits(words[...count].joined(separator: " "), first) { count += 1 }
        var line1: String, rest: String
        if count == 0 {
            // One word wider than line 1: as many of its characters as fit, the rest carries on.
            var cut = words[0].count
            while cut > 1, !fits(String(words[0].prefix(cut)), first) { cut -= 1 }
            line1 = String(words[0].prefix(cut))
            rest = ([String(words[0].dropFirst(cut))] + words.dropFirst()).joined(separator: " ")
        } else {
            line1 = words[..<count].joined(separator: " ")
            rest = words[count...].joined(separator: " ")
        }
        guard !rest.isEmpty else { return [line1] }
        if fits(rest, second) { return [line1, rest] }
        var shown = rest
        while !shown.isEmpty, !fits(shown.trimmingCharacters(in: .whitespaces) + "…", second) { shown.removeLast() }
        return [line1, shown.trimmingCharacters(in: .whitespaces) + "…"]
    }

    /// A title on two lines is 20 px (the design had 22): "Ten (Original" then fits line 1 whole (#165 follow-up).
    static let twoLineSize: CGFloat = 20

    /// The safe circle's width at a line box's farther edge from the center.
    private static func chord(top: CGFloat, height: CGFloat) -> CGFloat {
        let dy = max(abs(top - center), abs(top + height - center))
        return 2 * sqrt(max(0, safe * safe - dy * dy))
    }

    /// One centered line whose CSS line box starts at `top`, cut with an ellipsis to the safe circle's chord there.
    private static func line(_ text: TextLine, in context: CGContext) {
        guard !text.string.isEmpty else { return }
        let font = CTFontCreateWithName(text.font as CFString, text.size, nil)
        let height = lineBoxHeight(font, lineHeight: text.lineHeight)
        draw(fitted(text), font: font, centerX: center, centerY: text.top + height / 2, in: context)
    }

    /// The line as drawn: cut with an ellipsis to the safe circle's chord at its box.
    private static func fitted(_ text: TextLine) -> CTLine {
        _ = fontsRegistered
        let font = CTFontCreateWithName(text.font as CFString, text.size, nil)
        let height = lineBoxHeight(font, lineHeight: text.lineHeight)
        return fit(makeLine(text.string, font: font, color: text.color, tracking: text.tracking), font: font, top: text.top,
                   height: height)
    }

    /// The characters a line shows once cut: when cut, the last glyph run is the ellipsis, standing for the rest.
    static func shown(_ text: TextLine) -> String {
        guard !text.string.isEmpty else { return "" }
        let line = fitted(text)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        let font = CTFontCreateWithName(text.font as CFString, text.size, nil)
        let whole = makeLine(text.string, font: font, color: text.color, tracking: text.tracking)
        guard CTLineGetTypographicBounds(line, nil, nil, nil) < CTLineGetTypographicBounds(whole, nil, nil, nil),
              let last = runs.last else { return text.string }
        let kept = (text.string as NSString).substring(to: CTRunGetStringRange(last).location)
        return kept + "…"
    }

    /// A CSS line box's height: `lineHeight` × the size, or the font's own ascent + descent + leading for "normal".
    private static func lineBoxHeight(_ font: CTFont, lineHeight: CGFloat?) -> CGFloat {
        if let lineHeight { return lineHeight * CTFontGetSize(font) }
        return CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }

    /// The line cut with an ellipsis to the width of the safe circle at the box's farther edge from the center.
    private static func fit(_ line: CTLine, font: CTFont, top: CGFloat, height: CGFloat) -> CTLine {
        let dy = max(abs(top - center), abs(top + height - center))
        let width = 2 * sqrt(max(0, safe * safe - dy * dy))
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > width else { return line }
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        let attributes = runs.first.map { CTRunGetAttributes($0) as! [NSAttributedString.Key: Any] } ?? [:]
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        return CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis) ?? line
    }

    private static func makeLine(_ string: String, font: CTFont, color: CGColor, tracking: CGFloat = 0) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
            kCTKernAttributeName as NSAttributedString.Key: tracking * CTFontGetSize(font),
        ]))
    }

    /// Draws a line centered on (centerX, centerY) the way CSS centers text in its line box: the baseline at
    /// centerY + (ascent − descent) / 2.
    private static func draw(_ line: CTLine, font: CTFont, centerX: CGFloat, centerY: CGFloat, in context: CGContext) {
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let baseline = centerY + (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2
        context.saveGState()
        context.textMatrix = .identity
        // CoreText draws y up: flip around the baseline.
        context.translateBy(x: centerX - width / 2, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: Colors

    private static func rgb(_ hex: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    private static func color(_ rgb: [Int]) -> CGColor {
        guard rgb.count == 3 else { return text }
        return CGColor(srgbRed: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255, alpha: 1)
    }
}
