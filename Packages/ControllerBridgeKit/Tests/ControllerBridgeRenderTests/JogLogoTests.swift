import CoreGraphics
import Foundation
@testable import ControllerBridgeRender
import Testing

/// The jog display's logo (#464) is drawn from numbers, not from the icon file. This reads the icon itself, so a change
/// to design/icon/icon-1-deck-ring.svg that the jog display doesn't follow fails here.
@Suite("Jog display logo")
struct JogLogoTests {
    static let svg: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // the package
            .deletingLastPathComponent().deletingLastPathComponent()                                 // the repo
            .appendingPathComponent("design/icon/icon-1-deck-ring.svg")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// Every `<tag .../>` element, as its attributes.
    static func elements(_ tag: String) -> [[String: String]] {
        let element = try! NSRegularExpression(pattern: "<\(tag)\\b([^>]*)/>")
        let attribute = try! NSRegularExpression(pattern: "([a-z-]+)=\"([^\"]*)\"")
        return element.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).map { match in
            let body = String(svg[Range(match.range(at: 1), in: svg)!])
            var attributes: [String: String] = [:]
            for pair in attribute.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                attributes[String(body[Range(pair.range(at: 1), in: body)!])] = String(body[Range(pair.range(at: 2), in: body)!])
            }
            return attributes
        }
    }

    static func hex(_ color: Int) -> String { String(format: "#%06X", color) }
    static func number(_ text: String?) -> CGFloat { CGFloat(Double(text ?? "") ?? .nan) }

    @Test("The icon file is there to compare with")
    func iconExists() { #expect(Self.svg.contains("<svg")) }

    @Test("The logo's circles are the icon's: the inner disc, the hub and its hole, all on the center")
    func circles() {
        let circles = Self.elements("circle").map { (Self.number($0["cx"]), Self.number($0["cy"]), Self.number($0["r"]), $0["fill"] ?? "") }
        let ours = [JogLogo.innerDisc, JogLogo.hub, JogLogo.hole]
        #expect(circles.count == ours.count)
        for (circle, mine) in zip(circles, ours) {
            #expect(circle.0 == JogLogo.middle && circle.1 == JogLogo.middle)
            #expect(circle.2 == mine.radius)
            #expect(circle.3.uppercased() == Self.hex(mine.color))
        }
    }

    @Test("The logo's arcs are the icon's: the same ends, radius, width and colors, in the same order")
    func arcs() {
        let path = try! NSRegularExpression(pattern: "^M([0-9.]+),([0-9.]+) A([0-9.]+),([0-9.]+) 0 0 1 ([0-9.]+),([0-9.]+)$")
        let paths = Self.elements("path")
        #expect(paths.count == JogLogo.arcs.count)
        for (element, arc) in zip(paths, JogLogo.arcs) {
            let d = element["d"] ?? ""
            guard let match = path.firstMatch(in: d, range: NSRange(d.startIndex..., in: d)) else {
                Issue.record("not a single arc: \(d)")
                continue
            }
            let values = (1...6).map { Self.number(String(d[Range(match.range(at: $0), in: d)!])) }
            #expect(CGPoint(x: values[0], y: values[1]) == arc.from)
            #expect(values[2] == JogLogo.arcRadius && values[3] == JogLogo.arcRadius)
            #expect(CGPoint(x: values[4], y: values[5]) == arc.to)
            #expect((element["stroke"] ?? "").uppercased() == Self.hex(arc.color))
            #expect(Self.number(element["stroke-width"]) == JogLogo.arcWidth)
            #expect(element["stroke-linecap"] == "butt")
        }
    }

    @Test("The logo's needle is the icon's turned rectangle")
    func needle() {
        let turned = Self.elements("rect").filter { ($0["transform"] ?? "").hasPrefix("rotate(") }
        #expect(turned.count == 1)
        guard let rect = turned.first else { return }
        #expect(CGRect(x: Self.number(rect["x"]), y: Self.number(rect["y"]), width: Self.number(rect["width"]),
                       height: Self.number(rect["height"])) == JogLogo.needle.rect)
        #expect(Self.number(rect["rx"]) == JogLogo.needle.corner)
        #expect(rect["transform"] == "rotate(\(Int(JogLogo.needle.degrees)) 512 512)")
        #expect((rect["fill"] ?? "").uppercased() == Self.hex(JogLogo.needle.color))
    }
}
