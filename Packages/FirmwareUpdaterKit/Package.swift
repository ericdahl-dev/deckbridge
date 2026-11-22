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
        .library(name: "PanelFlasher", targets: ["PanelFlasher"]),
        .library(name: "UnitCheck", targets: ["UnitCheck"]),
        .library(name: "LC6000Update", targets: ["LC6000Update"]),
        .library(name: "FirmwareRelease", targets: ["FirmwareRelease"]),
        .library(name: "PortHandoff", targets: ["PortHandoff"]),
        .executable(name: "firmware-release", targets: ["firmware-release"]),
    ],
    targets: [
        // Plain values the device finder and the catalog share: what was found, and how versions compare. No logic
        // beyond comparing, so the finder never sees the catalog and the catalog never touches a device.
        .target(name: "FirmwareModel"),
        // The firmware the app ships with (#686): the deck panel image and the LC6000 patch descriptions, with the
        // rules for what applies to what. Built-in resources only; no network.
        .target(name: "FirmwareCatalog", dependencies: ["FirmwareModel"], resources: [.copy("Catalog")]),
        // Signed firmware releases (#689, ADR 0012): the manifest, its Ed25519 signature, and fetching a release newer
        // than the built-in one. A fetched release is checked, then loaded as a Catalog, so the catalog's guards apply.
        .target(name: "FirmwareRelease", dependencies: ["FirmwareCatalog", "FirmwareModel"]),
        // The maintainer's signing step (ADR 0012): makes the two keys, prints their public halves, signs a release
        // folder. A thin shell over FirmwareRelease; the passphrase is read from the terminal only.
        .executableTarget(name: "firmware-release", dependencies: ["FirmwareRelease", "FirmwareModel"]),
        .testTarget(name: "FirmwareReleaseTests", dependencies: ["FirmwareRelease", "FirmwareCatalog", "FirmwareModel"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "FirmwareCatalogTests", dependencies: ["FirmwareCatalog", "FirmwareModel"], resources: [.copy("Fixtures")]),
        // What is plugged in (#685), over read-only ports: the USB devices, the MIDI port names and a panel's serial
        // lines. It only looks: nothing here can send to a device. The real ports are the app's adapters.
        .target(name: "DeviceFinder", dependencies: ["FirmwareModel"]),
        // The app's two sections, deck panel and LC6000, as plain values: what the owner reads (#685).
        .target(name: "UpdaterScreen", dependencies: ["DeviceFinder", "FirmwareModel", "PortHandoff", "PanelFlasher", "FirmwareCatalog"]),
        // Borrowing the deck panel's USB port from DeckBridge for an update (#710): ask, wait for its answer, give it
        // back. Signals between the two apps on this Mac only; the app's adapter carries them. Never opens a port.
        .target(name: "PortHandoff"),
        .testTarget(name: "PortHandoffTests", dependencies: ["PortHandoff"]),
        .testTarget(name: "UpdaterScreenTests", dependencies: ["UpdaterScreen", "DeviceFinder", "FirmwareModel", "PortHandoff", "PanelFlasher", "FirmwareCatalog"]),
                // Flashing a deck panel over its USB cable (#687): the ESP32-S3 ROM's serial bootloader protocol, spoken over a
        // line the app opens. Tested against a fake bootloader; the real port is the app's adapter.
        .target(name: "PanelFlasher", dependencies: ["DeviceFinder", "FirmwareModel"]),
        .testTarget(name: "PanelFlasherTests", dependencies: ["PanelFlasher", "DeviceFinder", "FirmwareModel"]),
        // The LC6000 unit check and backup (#692): reads a chip in ST's update mode (DFU) and writes nothing to it. A
        // port of tools/lc6000-firmware's read-only steps (flash-day.sh, dfupatch.py, drawn_plan.py), the reference.
        .target(name: "UnitCheck", dependencies: ["FirmwareModel", "DeviceFinder"]),
        .testTarget(name: "UnitCheckTests", dependencies: ["UnitCheck", "FirmwareModel", "DeviceFinder"]),
        // The guarded LC6000 update (#693): the patched image built from the backup and the catalog's patch set, the
        // sectors it changes, and writing them over DFU only after the owner's confirm, then reading back. Restore
        // writes the backup's same sectors. Tested on a fake DFU device; the owner runs every write on a unit.
        .target(name: "LC6000Update", dependencies: ["UnitCheck", "FirmwareCatalog", "FirmwareModel", "DeviceFinder"]),
        .testTarget(name: "LC6000UpdateTests", dependencies: ["LC6000Update", "UnitCheck", "FirmwareCatalog", "FirmwareModel", "DeviceFinder"]),
    ]
)
