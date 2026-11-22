import Foundation

/// An HTTP answer as the feed sees it: a redirect's Location is handed back, never followed by the client, so the feed
/// decides where it goes.
public struct HTTPResponse: Sendable {
    public let status: Int
    public let location: String?
    public let body: Data

    public init(status: Int, location: String? = nil, body: Data) {
        self.status = status
        self.location = location
        self.body = body
    }
}

/// One GET. The app's adapter is URLSession with redirects off; tests use a fake.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
}

/// Why the GitHub feed gave nothing. ReleaseFetcher treats any of them as unreachable.
public enum FeedError: Error, Equatable {
    case http(Int)
    /// A file the release doesn't have, or one asked for before `latest()` found the release.
    case missingAsset(String)
    /// A URL the feed won't ask: not this repo's download URL, or a redirect off GitHub's asset hosts.
    case refusedURL(String)
    /// No release is published, or the newest has no manifest.json and manifest.sig: no signed firmware release yet.
    case nothingPublished
}

/// This project's newest published GitHub release (#704), over github.com's plain download links: no API, so no
/// 60-an-hour limit shared by the whole network. It sends a generic client name and nothing about the user, and holds
/// no token. Drafts and pre-releases are never fetched: GitHub's latest link only resolves the newest published,
/// non-draft, non-prerelease release (GitHub's docs).
public actor GitHubReleaseFeed: ReleaseFeed {
    /// The newest release's manifest: GitHub redirects it to the release's own download URL, which names its tag.
    static let latestURL = URL(string: "https://github.com/ericdahl-dev/deckbridge/releases/latest/download/manifest.json")!
    /// Every request's headers, and only these: no Authorization, no cookies.
    static let headers = ["User-Agent": "DeckBridge-Firmware-Updater", "Accept": "application/vnd.github+json"]

    /// Where an asset's download URL must be: this repo's releases on github.com.
    static let downloadPrefix = "/ericdahl-dev/deckbridge/releases/download/"
    /// Where GitHub's download URL redirects for the bytes: one hop, to one of these, https.
    static let assetHosts: Set<String> = ["objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    let http: any HTTPClient
    /// The newest release's tag, from GitHub's first hop: every file comes from this one release.
    private var tag: String?

    public init(http: any HTTPClient) { self.http = http }

    public func latest() async throws -> PublishedRelease {
        let answer = try await http.get(Self.latestURL, headers: Self.headers)
        // 404: nothing is published, or the newest release has no manifest.
        if answer.status == 404 { throw FeedError.nothingPublished }
        guard (300..<400).contains(answer.status), let location = answer.location else { throw FeedError.http(answer.status) }
        guard let url = URL(string: location), let tag = Self.tag(ofManifest: url) else { throw FeedError.refusedURL(location) }
        self.tag = tag
        let manifest = try await file("manifest.json")
        let signature: Data
        do { signature = try await file("manifest.sig") }
        catch FeedError.missingAsset { throw FeedError.nothingPublished }
        return PublishedRelease(manifest: manifest, signature: signature)
    }

    /// One file of the release `latest()` found, by its asset name: from this repo's download URL for that tag on
    /// github.com, then, if GitHub redirects, from the one asset host it names. Any other URL, or a second redirect, is
    /// refused before it is asked.
    public func file(_ name: String) async throws -> Data {
        guard let tag else { throw FeedError.missingAsset(name) }
        let given = "https://github.com" + Self.downloadPrefix + tag + "/" + name
        guard let url = URL(string: given), Self.isDownload(url) else { throw FeedError.refusedURL(given) }
        let first = try await http.get(url, headers: Self.headers)
        if first.status == 200 { return first.body }
        // github.com's 404: the release has no such file. (A 404 from the asset host is a failed download.)
        if first.status == 404 { throw FeedError.missingAsset(name) }
        guard (300..<400).contains(first.status), let location = first.location else { throw FeedError.http(first.status) }
        guard let stored = URL(string: location), Self.isAssetHost(stored) else { throw FeedError.refusedURL(location) }
        let second = try await http.get(stored, headers: Self.headers)
        guard second.status == 200 else { throw FeedError.http(second.status) }
        return second.body
    }

    /// The tag in https://github.com/ericdahl-dev/deckbridge/releases/download/<tag>/manifest.json, or nil for any
    /// other URL. The tag is one plain path part.
    static func tag(ofManifest url: URL) -> String? {
        guard isDownload(url) else { return nil }
        let parts = url.path(percentEncoded: false).dropFirst(downloadPrefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "manifest.json", !parts[0].isEmpty else { return nil }
        return String(parts[0])
    }

    /// https://github.com/ericdahl-dev/deckbridge/releases/download/…, with no "." or ".." parts.
    static func isDownload(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        return url.scheme == "https" && url.host() == "github.com" && url.port == nil && url.user() == nil
            && path.hasPrefix(downloadPrefix) && !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    static func isAssetHost(_ url: URL) -> Bool {
        url.scheme == "https" && assetHosts.contains(url.host() ?? "") && url.port == nil && url.user() == nil
    }
}
