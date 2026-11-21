// swift-tools-version: 6.2
import PackageDescription

// The firmware updater (spec #684): a separate Mac app, sharing nothing at runtime with DeckBridge.
let package = Package(
    name: "FirmwareUpdaterKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FirmwareModel", targets: ["FirmwareModel"]),
        .library(name: "FirmwareCatalog", targets: ["FirmwareCatalog"]),
        .library(name: "DeviceFinder", targets: ["DeviceFinder"]),
        .library(name: "UpdaterScreen", targets: ["UpdaterScreen"]),
        .library(name: "UnitCheck", targets: ["UnitCheck"]),
    ],
    targets: [
        // Plain values the device finder and the catalog share: what was found, and how versions compare. No logic
        // beyond comparing, so the finder never sees the catalog and the catalog never touches a device.
        .target(name: "FirmwareModel"),
        // The firmware the app ships with (#686): the deck panel image and the LC6000 patch descriptions, with the
        // rules for what applies to what. Built-in resources only; no network.
        .target(name: "FirmwareCatalog", dependencies: ["FirmwareModel"], resources: [.copy("Catalog")]),
        .testTarget(name: "FirmwareCatalogTests", dependencies: ["FirmwareCatalog", "FirmwareModel"], resources: [.copy("Fixtures")]),
        // What is plugged in (#685), over read-only ports: the USB devices, the MIDI port names and a panel's serial
        // lines. It only looks: nothing here can send to a device. The real ports are the app's adapters.
        .target(name: "DeviceFinder", dependencies: ["FirmwareModel"]),
        // The app's two sections, deck panel and LC6000, as plain values: what the owner reads (#685).
        .target(name: "UpdaterScreen", dependencies: ["DeviceFinder", "FirmwareModel"]),
        .testTarget(name: "UpdaterScreenTests", dependencies: ["UpdaterScreen", "DeviceFinder", "FirmwareModel"]),
        // The LC6000 unit check and backup (#692): reads a chip in ST's update mode (DFU) and writes nothing to it. A
        // port of tools/lc6000-firmware's read-only steps (flash-day.sh, dfupatch.py, drawn_plan.py), the reference.
        .target(name: "UnitCheck", dependencies: ["FirmwareModel"]),
        .testTarget(name: "UnitCheckTests", dependencies: ["UnitCheck", "FirmwareModel"]),
    ]
)
