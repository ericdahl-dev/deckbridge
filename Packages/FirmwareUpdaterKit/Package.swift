// swift-tools-version: 6.2
import PackageDescription

// The firmware updater (spec #684): a separate Mac app, sharing nothing at runtime with DeckBridge.
let package = Package(
    name: "FirmwareUpdaterKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FirmwareModel", targets: ["FirmwareModel"]),
        .library(name: "FirmwareCatalog", targets: ["FirmwareCatalog"]),
        .library(name: "FirmwareRelease", targets: ["FirmwareRelease"]),
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
    ]
)
