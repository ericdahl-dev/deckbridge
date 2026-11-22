// Our logo, the app icon's deck ring (design/icon/icon-1-deck-ring.svg, without its tile), as the jog display's
// waiting look draws it (#464). The numbers are the SVG's own, in its 1024-unit space; a test reads the SVG and checks
// them, so a change to the icon shows up here. The display firmware draws the same shapes from the same numbers.
import CoreGraphics

enum JogLogo {
    /// The SVG's center, in its units.
    static let middle: CGFloat = 512
    /// On the jog display: the arcs' outer edge (300 units) lands at 72 px, inside the text-safe circle (79).
    static let scale: CGFloat = 0.24

    static let innerDisc = (radius: CGFloat(206), color: 0x1D1D1E)
    /// The four arcs, clockwise from the top right: radius 262, stroke 76, butt ends, from one point to the other.
    static let arcRadius: CGFloat = 262, arcWidth: CGFloat = 76
    static let arcs: [(from: CGPoint, to: CGPoint, color: Int)] = [
        (CGPoint(x: 543.9, y: 252.0), CGPoint(x: 772.0, y: 480.1), 0x6C7277),
        (CGPoint(x: 772.0, y: 543.9), CGPoint(x: 543.9, y: 772.0), 0xECCF65),
        (CGPoint(x: 480.1, y: 772.0), CGPoint(x: 252.0, y: 543.9), 0xC5754E),
        (CGPoint(x: 252.0, y: 480.1), CGPoint(x: 480.1, y: 252.0), 0x62929E),
    ]
    /// The needle: a rounded rectangle turned about the middle.
    static let needle = (rect: CGRect(x: 497, y: 202, width: 30, height: 166), corner: CGFloat(15), degrees: CGFloat(40),
                         color: 0xD5D5D5)
    static let hub = (radius: CGFloat(74), color: 0xD5D5D5)
    static let hole = (radius: CGFloat(26), color: 0x141415)

    /// Draws it centered on `center`, in a context with y down.
    /// `hub`, when given, fills the hub in that color with no hole (#524: the stale look's deck); the icon's own
    /// numbers stay as they are.
    static func draw(in context: CGContext, center: CGPoint, scale: CGFloat, hub hubFill: CGColor? = nil) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -middle, y: -middle)
        let mid = CGPoint(x: middle, y: middle)

        context.setFillColor(rgb(innerDisc.color))
        context.fillEllipse(in: circle(innerDisc.radius))
        context.setLineWidth(arcWidth)
        context.setLineCap(.butt)
        for arc in arcs {
            // Clockwise on screen, which with y down is increasing angle.
            let path = CGMutablePath()
            path.addArc(center: mid, radius: arcRadius, startAngle: angle(arc.from), endAngle: angle(arc.to), clockwise: false)
            context.addPath(path)
            context.setStrokeColor(rgb(arc.color))
            context.strokePath()
        }
        context.saveGState()
        context.translateBy(x: middle, y: middle)
        context.rotate(by: needle.degrees * .pi / 180)
        context.translateBy(x: -middle, y: -middle)
        context.addPath(CGPath(roundedRect: needle.rect, cornerWidth: needle.corner, cornerHeight: needle.corner, transform: nil))
        context.setFillColor(rgb(needle.color))
        context.fillPath()
        context.restoreGState()
        context.setFillColor(hubFill ?? rgb(hub.color))
        context.fillEllipse(in: circle(hub.radius))
        guard hubFill == nil else { return }
        context.setFillColor(rgb(hole.color))
        context.fillEllipse(in: circle(hole.radius))
    }

    private static func circle(_ radius: CGFloat) -> CGRect {
        CGRect(x: middle - radius, y: middle - radius, width: radius * 2, height: radius * 2)
    }

    private static func angle(_ point: CGPoint) -> CGFloat { atan2(point.y - middle, point.x - middle) }

    private static func rgb(_ hex: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}
