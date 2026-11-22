import CoreGraphics
import Foundation
@testable import ControllerBridgeRender
import Testing

/// The Mac App Store screenshot frame (#29): 2880×1800, a caption band across the top, and the shot fitted below it
/// inside 120 px margins, centered, never stretched out of its shape. Worked by hand: the shot area is x 120…2760,
/// y 360…1680 (2640×1320, 2:1).
@Suite("App Store frame layout")
struct AppStoreFrameTests {
    @Test("A shot of the area's own shape fills it: 1320×660 at 2x is 120, 360, 2640×1320")
    func sameShape() {
        let layout = AppStoreFrame.layout(shot: CGSize(width: 1320, height: 660))
        #expect(layout.shot == CGRect(x: 120, y: 360, width: 2640, height: 1320))
        #expect(layout.caption == CGRect(x: 120, y: 0, width: 2640, height: 360))
    }

    @Test("A tall panel (720×1056) fits the height, 1320, and is centered: 990, 360, 900×1320")
    func tall() {
        #expect(AppStoreFrame.layout(shot: CGSize(width: 720, height: 1056)).shot == CGRect(x: 990, y: 360, width: 900, height: 1320))
    }

    @Test("A wide shot (2500×800, wider than the area) fits the width: 120, 597.6, 2640×844.8")
    func wide() {
        let shot = AppStoreFrame.layout(shot: CGSize(width: 2500, height: 800)).shot
        #expect(shot.minX == 120 && shot.width == 2640)
        #expect(abs(shot.height - 844.8) < 0.001 && abs(shot.minY - 597.6) < 0.001)
    }
}

/// The composed frame (#29): Apple's sizes, flat RGB with no alpha (App Store Connect refuses alpha), the ground
/// color around the shot, the shot where the layout puts it, and a caption drawn in the band.
@Suite("App Store frame image")
struct AppStoreFrameImageTests {
    /// A solid red 100×50 shot.
    static func red() -> CGImage {
        let context = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 400,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        return context.makeImage()!
    }

    static let ground = CGColor(srgbRed: 0x0B / 255.0, green: 0x0B / 255.0, blue: 0x0B / 255.0, alpha: 1)

    /// The image's pixels, read once: `pixel(x, y)` is [r, g, b], top-left origin.
    struct Pixels {
        let data: Data, bytesPerRow: Int, bytesPerPixel: Int
        init(_ image: CGImage) {
            data = image.dataProvider!.data! as Data
            bytesPerRow = image.bytesPerRow
            bytesPerPixel = image.bitsPerPixel / 8
        }
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = y * bytesPerRow + x * bytesPerPixel
            return [data[offset], data[offset + 1], data[offset + 2]]
        }
    }

    @Test("2880×1800 and 1440×900, no alpha")
    func sizes() throws {
        let frames = try #require(AppStoreFrame.images(shot: Self.red(), caption: "Your controller in Syndicate",
                                                        ground: Self.ground, text: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)))
        #expect(frames.large.width == 2880 && frames.large.height == 1800)
        #expect(frames.small.width == 1440 && frames.small.height == 900)
        let opaque: [CGImageAlphaInfo] = [.none, .noneSkipLast, .noneSkipFirst]
        for image in [frames.large, frames.small] { #expect(opaque.contains(image.alphaInfo)) }
    }

    @Test("The ground in the margin, the shot in its rect, and caption ink in the band")
    func content() throws {
        let frames = try #require(AppStoreFrame.images(shot: Self.red(), caption: "Your controller in Syndicate",
                                                        ground: Self.ground, text: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)))
        let large = Pixels(frames.large)
        #expect(large.pixel(10, 10) == [UInt8(0x0B), 0x0B, 0x0B])
        // A 100×50 shot is 2:1, the area's own shape: x 120…2760, y 360…1680.
        #expect(large.pixel(1440, 980) == [UInt8(255), 0, 0])
        #expect(large.pixel(1440, 300) == [UInt8(0x0B), 0x0B, 0x0B])
        let band = (0..<280).flatMap { y in stride(from: 120, to: 2760, by: 8).map { large.pixel($0, y) } }
        #expect(band.contains { $0[0] > 200 && $0[1] > 200 && $0[2] > 200 }, "caption text drawn")
    }
}

/// The frame's ground matches the shot's own background (#29), read from its top-left corner, so a dark or light
/// shot sits on its own color.
@Suite("App Store frame ground")
struct AppStoreFrameGroundTests {
    @Test("The top-left pixel, not another: green there on a red 4×4 shot gives green")
    func topLeft() throws {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 3, width: 1, height: 1))     // CoreGraphics' y 3 is the image's top row
        let ground = try #require(AppStoreFrame.ground(of: context.makeImage()!))
        #expect(ground.components?.prefix(3).map { ($0 * 255).rounded() } == [0, 255, 0])
    }

    @Test("A red shot's ground is red")
    func sampled() throws {
        let ground = try #require(AppStoreFrame.ground(of: AppStoreFrameImageTests.red()))
        #expect(ground.components?.prefix(3).map { ($0 * 255).rounded() } == [255, 0, 0])
    }
}

/// As the 1.0 set looked (#29): a subtitle line under the caption, and a hairline round the shot so a shot on its own
/// ground still has an edge.
@Suite("App Store frame subtitle and edge")
struct AppStoreFrameSubtitleTests {
    static func frame(subtitle: String?) throws -> AppStoreFrameImageTests.Pixels {
        let frames = try #require(AppStoreFrame.images(shot: AppStoreFrameImageTests.red(), caption: "Try it with no hardware",
                                                        subtitle: subtitle, ground: AppStoreFrameImageTests.ground,
                                                        text: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)))
        return AppStoreFrameImageTests.Pixels(frames.large)
    }

    /// Whether rows `rows` of the band hold light ink.
    static func ink(_ pixels: AppStoreFrameImageTests.Pixels, rows: Range<Int>) -> Bool {
        rows.contains { y in stride(from: 120, to: 2760, by: 6).contains { x in pixels.pixel(x, y).allSatisfy { $0 > 120 } } }
    }

    @Test("With a subtitle there's ink low in the band (y 240…300); without one, none there")
    func subtitle() throws {
        #expect(Self.ink(try Self.frame(subtitle: "A built-in demo controller shows the bridge at work."), rows: 240..<300))
        #expect(!Self.ink(try Self.frame(subtitle: nil), rows: 240..<300))
    }

    @Test("A 2 px hairline 3 px outside the shot (red 100×50 starts at y 360: rows 356–357) differs from the ground")
    func edge() throws {
        let pixels = try Self.frame(subtitle: nil)
        #expect(pixels.pixel(1440, 357) != [UInt8(0x0B), 0x0B, 0x0B])
        #expect(pixels.pixel(1440, 350) == [UInt8(0x0B), 0x0B, 0x0B])
    }

    @Test("The frame's faces are the real Geist the Render target bundles, not a fallback", arguments: AppStoreFrame.faces)
    func faces(_ name: String) {
        _ = AppStoreFrame.layout(shot: CGSize(width: 1, height: 1))
        #expect(AppStoreFrame.resolves(name))
    }
}
