import CoreGraphics
import Foundation

/// The updater window's size (#761): as big as what it shows, so the owner never resizes it to read a section.
public enum WindowFit {
    /// Narrower than this, the longer lines wrap into a tall column.
    public static let minWidth: CGFloat = 560

    /// The window's size for `content` (the sections' own size) under a title bar `titleBar` tall, on a screen whose
    /// visible frame is `visible`. Never smaller than `handSet`, a size the owner set by hand; never bigger than the
    /// visible frame: past it, the content scrolls.
    public static func size(content: CGSize, titleBar: CGFloat, visible: CGSize, handSet: CGSize? = nil) -> CGSize {
        let floor = handSet ?? .zero
        return CGSize(width: min(max(content.width, minWidth, floor.width), visible.width),
                      height: min(max(content.height + titleBar, floor.height), visible.height))
    }
}

/// The window size the owner last set by hand (#761), kept in the app's defaults so it lasts across launches.
public struct HandSetSize {
    private let defaults: UserDefaults
    private static let key = "WindowFit.handSetSize"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The size last set by hand; nil when the owner never resized the window.
    public var size: CGSize? {
        guard let pair = defaults.array(forKey: Self.key) as? [Double], pair.count == 2 else { return nil }
        return CGSize(width: pair[0], height: pair[1])
    }

    public func remember(_ size: CGSize) {
        defaults.set([Double(size.width), Double(size.height)], forKey: Self.key)
    }
}
