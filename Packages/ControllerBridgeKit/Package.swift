// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ControllerBridgeKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ControllerBridgeCore", targets: ["ControllerBridgeCore"]),
        .library(name: "ControllerBridgePresentation", targets: ["ControllerBridgePresentation"]),
        .library(name: "ControllerBridgeCapture", targets: ["ControllerBridgeCapture"]),
        .library(name: "ControllerBridgeRender", targets: ["ControllerBridgeRender"]),
        .library(name: "ControllerBridgeDraft", targets: ["ControllerBridgeDraft"]),
    ],
    targets: [
        // All bridge logic: the Coordinator, the Bridge, the mapping and the OSC codec.
        // Pure Swift: no CoreMIDI, no Network framework, no UI.
        .target(name: "ControllerBridgeCore", resources: [.copy("Resources/Profiles")]),
        // Resources holds test-only profiles, such as a second controller that ships in no app.
        .testTarget(name: "ControllerBridgeCoreTests", dependencies: ["ControllerBridgeCore"], resources: [.copy("Resources")]),
        // What the UI shows, as plain values: colors, contrast, deck badges and status words. No SwiftUI, so the
        // logic behind the look is tested here; the views themselves are checked by screenshot (#34).
        .target(name: "ControllerBridgePresentation"),
        // Core only for the test that pins the deck badges to Core's deck colors (#122); the targets stay independent.
        .testTarget(name: "ControllerBridgePresentationTests", dependencies: ["ControllerBridgePresentation", "ControllerBridgeCore"]),
        // Guided controller capture (#185): a prompt list plus raw MIDI in, a capture file out. Pure Swift and independent
        // of Core, so the web capture (#190) can share the format without the bridge.
        .target(name: "ControllerBridgeCapture", resources: [.copy("Resources/capture-prompts-dj.json")]),
        .testTarget(name: "ControllerBridgeCaptureTests", dependencies: ["ControllerBridgeCapture"]),
        // The LC6000 jog display's image (#165), shared by the upload and the Diagnostics simulator (#221): CoreGraphics
        // and CoreText, with the Geist faces it draws in (SIL OFL 1.1, Fonts/Geist-OFL.txt), so it renders the same
        // under swift test as in the app.
        .target(name: "ControllerBridgeRender", dependencies: ["ControllerBridgeCore"], resources: [.copy("Fonts")]),
        .testTarget(name: "ControllerBridgeRenderTests", dependencies: ["ControllerBridgeRender", "ControllerBridgeCore"]),
        // A draft controller profile from a capture file plus docs facts (#189): developer tooling, so it may join
        // Capture and Core. The capture wins over the docs; whatever neither knows is a TODO, never a guess.
        .target(name: "ControllerBridgeDraft", dependencies: ["ControllerBridgeCapture", "ControllerBridgeCore"]),
        // scripts/capture_to_profile: the draft tool's command line, a thin shell over ControllerBridgeDraft.
        // scripts/appstore_screenshots.sh: frames a Debug snapshot for the Mac App Store, a thin shell over AppStoreFrame.
        .executableTarget(name: "appstore-frames", dependencies: ["ControllerBridgeRender"]),
        // tools/lc6000-display-fw/test/ref/make_refs.sh: the drawn display firmware's reference images (#457), from the
        // renderer itself, so the C code is never checked against its own output.
        .executableTarget(name: "jog-reference", dependencies: ["ControllerBridgeRender", "ControllerBridgeCore"]),
        .executableTarget(name: "capture-to-profile", dependencies: ["ControllerBridgeDraft", "ControllerBridgeCapture"]),
        .testTarget(name: "ControllerBridgeDraftTests", dependencies: ["ControllerBridgeDraft", "ControllerBridgeCapture", "ControllerBridgeCore"]),
        // scripts/syndicate_deck (#680): drives a Syndicate deck over OSC for on-hardware tests, with Core's own messages
        // and encoder, so its bytes are the app's. Never MIDI, so it can't reach a controller; settings read only.
        .target(name: "SyndicateDeck", dependencies: ["ControllerBridgeCore"]),
        .executableTarget(name: "syndicate-deck", dependencies: ["SyndicateDeck"]),
        .testTarget(name: "SyndicateDeckTests", dependencies: ["SyndicateDeck", "ControllerBridgeCore"]),
    ]
)
