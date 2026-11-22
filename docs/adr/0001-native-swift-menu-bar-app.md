# A native Swift menu-bar app replaces the Python bridge

2026-11-16. The bridge began as a Python script. We rebuilt it as a native macOS menu-bar app in Swift (#12, #14) and removed the Python bridge (#30), because DJs need a signed app they install once from TestFlight and the Mac App Store, not a terminal and a Python install, and because CoreMIDI, the sandbox and notarization are first-class there. The bridge logic lives in a Swift package (ControllerBridgeKit) so it is tested without the app. The Python monitor's output formats were kept so hardware checks read the same.
