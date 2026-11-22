import CoreGraphics

/// The updater window's size (#761): as big as what it shows, so the owner never resizes it to read a section.
public enum WindowFit {
    /// Narrower than this, the longer lines wrap into a tall column.
    public static let minWidth: CGFloat = 560

    /// The window's size for `content` (the sections' own size) under a title bar `titleBar` tall, on a screen whose
    /// visible frame is `visible`. Never bigger than that frame: past it, the content scrolls.
    public static func size(content: CGSize, titleBar: CGFloat, visible: CGSize) -> CGSize {
        CGSize(width: min(max(content.width, minWidth), visible.width),
               height: min(content.height + titleBar, visible.height))
    }
}
