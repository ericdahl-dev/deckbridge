import CoreGraphics

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
