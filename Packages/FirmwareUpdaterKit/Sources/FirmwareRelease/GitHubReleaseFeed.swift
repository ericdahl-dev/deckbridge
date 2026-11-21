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
}

/// This project's newest published GitHub release (#704), read over GitHub's public, unauthenticated endpoints. It sends
/// a generic client name and nothing about the user, and holds no token.
public actor GitHubReleaseFeed: ReleaseFeed {
    static let latestURL = URL(string: "https://api.github.com/repos/ericdahl-dev/deckbridge/releases/latest")!
    /// Every request's headers, and only these: no Authorization, no cookies.
    static let headers = ["User-Agent": "DeckBridge-Firmware-Updater", "Accept": "application/vnd.github+json"]

    let http: any HTTPClient
    /// The release `latest()` read: each asset's download URL, by name.
    private var assets: [String: URL] = [:]

    public init(http: any HTTPClient) { self.http = http }

    public func latest() async throws -> PublishedRelease {
        let answer = try await http.get(Self.latestURL, headers: Self.headers)
        guard answer.status == 200 else { throw FeedError.http(answer.status) }
        guard let release = try? JSONDecoder().decode(Release.self, from: answer.body) else { throw FeedError.notARelease }
        assets = [:]
        for asset in release.assets { if let url = URL(string: asset.browser_download_url) { assets[asset.name] = url } }
        return PublishedRelease(manifest: try await file("manifest.json"), signature: try await file("manifest.sig"))
    }

    public func file(_ name: String) async throws -> Data {
        guard let url = assets[name] else { throw FeedError.missingAsset(name) }
        let first = try await http.get(url, headers: Self.headers)
        if first.status == 200 { return first.body }
        guard (300..<400).contains(first.status), let location = first.location, let stored = URL(string: location) else {
            throw FeedError.http(first.status)
        }
        let second = try await http.get(stored, headers: Self.headers)
        guard second.status == 200 else { throw FeedError.http(second.status) }
        return second.body
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let assets: [Asset]
    }
}
