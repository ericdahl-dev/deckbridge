// appstore-frames <shot.png> <caption> <subtitle> <out-prefix> (#29)
// Writes <out-prefix>-2880x1800.png and <out-prefix>-1440x900.png: the shot framed with its caption on its own ground,
// flat RGB. Text color: white on a dark ground, near-black on a light one.
import ControllerBridgeRender
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 4 else { fail("Usage: appstore-frames <shot.png> <caption> <subtitle> <out-prefix>") }
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[0]) as CFURL, nil),
      let shot = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Can't read \(arguments[0])") }
guard let ground = AppStoreFrame.ground(of: shot), let parts = ground.components else { fail("Can't read the shot's ground") }
let light = 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2] > 0.5
let text = light ? CGColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 1) : CGColor(srgbRed: 0.93, green: 0.93, blue: 0.92, alpha: 1)
guard let frames = AppStoreFrame.images(shot: shot, caption: arguments[1], subtitle: arguments[2].isEmpty ? nil : arguments[2], ground: ground, text: text) else { fail("Can't draw the frame") }
for (image, size) in [(frames.large, "2880x1800"), (frames.small, "1440x900")] {
    let url = URL(fileURLWithPath: "\(arguments[3])-\(size).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("Can't write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("Can't write \(url.path)") }
    print(url.path)
}
