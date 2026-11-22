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
    case notARelease
    case missingAsset(String)
    /// A draft or a pre-release: never fetched.
    case notPublished
    /// A URL the feed won't ask: not this repo's download URL, or a redirect off GitHub's asset hosts.
    case refusedURL(String)
    /// The newest release has no manifest.json and manifest.sig: no signed firmware release is published.
    case nothingPublished
}

/// This project's newest published GitHub release (#704), read over GitHub's public, unauthenticated endpoints. It sends
/// a generic client name and nothing about the user, and holds no token.
public actor GitHubReleaseFeed: ReleaseFeed {
    static let latestURL = URL(string: "https://api.github.com/repos/ericdahl-dev/deckbridge/releases/latest")!
    /// Every request's headers, and only these: no Authorization, no cookies.
    static let headers = ["User-Agent": "DeckBridge-Firmware-Updater", "Accept": "application/vnd.github+json"]

    /// Where an asset's download URL must be: this repo's releases on github.com.
    static let downloadPrefix = "/ericdahl-dev/deckbridge/releases/download/"
    /// Where GitHub's download URL redirects for the bytes: one hop, to one of these, https.
    static let assetHosts: Set<String> = ["objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    let http: any HTTPClient
    /// The release `latest()` read: each asset's download URL as given, by name; checked when it's fetched.
    private var assets: [String: String] = [:]

    public init(http: any HTTPClient) { self.http = http }

    public func latest() async throws -> PublishedRelease {
        let answer = try await http.get(Self.latestURL, headers: Self.headers)
        guard answer.status == 200 else { throw FeedError.http(answer.status) }
        guard let release = try? JSONDecoder().decode(Release.self, from: answer.body) else { throw FeedError.notARelease }
        // GitHub's "latest" is never a draft or a pre-release; if it ever were, nothing of it is fetched.
        guard !release.draft, !release.prerelease else { throw FeedError.notPublished }
        assets = [:]
        for asset in release.assets { assets[asset.name] = asset.browser_download_url }
        guard assets["manifest.json"] != nil, assets["manifest.sig"] != nil else { throw FeedError.nothingPublished }
        return PublishedRelease(manifest: try await file("manifest.json"), signature: try await file("manifest.sig"))
    }

    /// One asset of the release `latest()` read: from its download URL on github.com, then, if GitHub redirects, from
    /// the one asset host it names. Any other URL, or a second redirect, is refused before it is asked.
    public func file(_ name: String) async throws -> Data {
        guard let given = assets[name] else { throw FeedError.missingAsset(name) }
        guard let url = URL(string: given), Self.isDownload(url) else { throw FeedError.refusedURL(given) }
        let first = try await http.get(url, headers: Self.headers)
        if first.status == 200 { return first.body }
        guard (300..<400).contains(first.status), let location = first.location else { throw FeedError.http(first.status) }
        guard let stored = URL(string: location), Self.isAssetHost(stored) else { throw FeedError.refusedURL(location) }
        let second = try await http.get(stored, headers: Self.headers)
        guard second.status == 200 else { throw FeedError.http(second.status) }
        return second.body
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

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
}
