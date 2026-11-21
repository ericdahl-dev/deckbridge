import Foundation
import Testing
import FirmwareRelease

// The real release feed (#704): this project's newest published GitHub release, read over public endpoints only.

/// GitHub as the feed sees it: each URL's answer, and every request asked, with its headers.
final class FakeGitHub: HTTPClient, @unchecked Sendable {
    var answers: [String: HTTPResponse] = [:]
    var asked: [(url: String, headers: [String: String])] = []
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        asked.append((url.absoluteString, headers))
        guard let answer = answers[url.absoluteString] else { return HTTPResponse(status: 404, body: Data()) }
        return answer
    }
}

let latestURL = "https://api.github.com/repos/ericdahl-dev/deckbridge/releases/latest"
let downloads = "https://github.com/ericdahl-dev/deckbridge/releases/download/deck-panel-v1.1.0/"

/// A published release's JSON as GitHub's REST API gives it (the fields the feed reads, and a few it doesn't).
func releaseJSON(draft: Bool = false, prerelease: Bool = false, assets: [String] = ["manifest.json", "manifest.sig", "catalog.json"]) -> Data {
    let listed = assets.map { #"{"name": "\#($0)", "size": 10, "browser_download_url": "\#(downloads)\#($0)", "url": "https://api.github.com/repos/ericdahl-dev/deckbridge/releases/assets/1"}"# }
    return Data(#"{"tag_name": "deck-panel-v1.1.0", "draft": \#(draft), "prerelease": \#(prerelease), "assets": [\#(listed.joined(separator: ","))]}"#.utf8)
}

/// GitHub's download URL redirects to its asset host; the asset host serves the bytes.
func serve(_ name: String, _ bytes: Data, on github: FakeGitHub, host: String = "objects.githubusercontent.com") {
    let stored = "https://\(host)/github-production-release-asset/\(name)?sig=x"
    github.answers[downloads + name] = HTTPResponse(status: 302, location: stored, body: Data())
    github.answers[stored] = HTTPResponse(status: 200, body: bytes)
}

func publishedGitHub() -> FakeGitHub {
    let github = FakeGitHub()
    github.answers[latestURL] = HTTPResponse(status: 200, body: releaseJSON())
    serve("manifest.json", Data("the manifest".utf8), on: github)
    serve("manifest.sig", Data("the signature".utf8), on: github)
    return github
}

@Test func theLatestReleaseIsItsManifestAndSignatureFetchedOverPublicEndpointsOnly() async throws {
    let github = publishedGitHub()
    let release = try await GitHubReleaseFeed(http: github).latest()
    #expect(release.manifest == Data("the manifest".utf8))
    #expect(release.signature == Data("the signature".utf8))
    #expect(github.asked.first?.url == latestURL)
    // No token, no cookie, nothing about the user: a generic client name and what it accepts, the same on every request.
    for request in github.asked {
        #expect(request.headers == ["User-Agent": "DeckBridge-Firmware-Updater", "Accept": "application/vnd.github+json"])
    }
    #expect(github.asked.count == 5)  // the release, then each asset's download URL and its redirect
}
