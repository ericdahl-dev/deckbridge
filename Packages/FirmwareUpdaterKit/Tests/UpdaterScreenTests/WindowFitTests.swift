import CoreGraphics
import Testing
import UpdaterScreen

/// The updater's window fits what it shows (#761): the owner never has to resize it to read a section.
@Suite("Updater: the window fits its content")
struct WindowFitTests {
    /// A 13-inch MacBook Air's screen at its default scale, less the menu bar and Dock.
    static let laptop = CGSize(width: 1470, height: 860)

    @Test("It opens as tall as the content plus the title bar, and at least the minimum width")
    func opensToFit() {
        let size = WindowFit.size(content: CGSize(width: 420, height: 640), titleBar: 28, visible: Self.laptop)
        #expect(size == CGSize(width: 560, height: 668))
    }

    @Test("Content wider than the minimum keeps its own width")
    func wideContent() {
        let size = WindowFit.size(content: CGSize(width: 700, height: 300), titleBar: 28, visible: Self.laptop)
        #expect(size == CGSize(width: 700, height: 328))
    }

    @Test("Content taller than the screen: the window stops at the screen's visible height, and the content scrolls")
    func tallerThanScreen() {
        let size = WindowFit.size(content: CGSize(width: 560, height: 1200), titleBar: 28, visible: Self.laptop)
        #expect(size == CGSize(width: 560, height: 860))
    }

    @Test("Content wider than the screen: the window stops at the screen's visible width")
    func widerThanScreen() {
        let size = WindowFit.size(content: CGSize(width: 2000, height: 300), titleBar: 28, visible: Self.laptop)
        #expect(size == CGSize(width: 1470, height: 328))
    }
}
