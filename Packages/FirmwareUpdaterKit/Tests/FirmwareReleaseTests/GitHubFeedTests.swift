import Foundation
import Testing
import FirmwareCatalog
import FirmwareModel
import FirmwareRelease

// The real release feed (#704): this project's newest published GitHub release, read over public endpoints only.

/// GitHub as the feed sees it: each URL's answer, and every request asked, with its headers.
final class FakeGitHub: HTTPClient, @unchecked Sendable {
    var answers: [String: HTTPResponse] = [:]
    var asked: [(url: String, headers: [String: String])] = []
    /// URLs whose request fails outright: the network is down, or it timed out.
    var timingOut: Set<String> = []
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        asked.append((url.absoluteString, headers))
        if timingOut.contains(url.absoluteString) { throw URLError(.timedOut) }
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

/// GitHub's "latest" never names a draft or a pre-release; should it ever, nothing of that release is fetched.
@Test(arguments: [(true, false), (false, true)])
func aDraftOrPreReleaseIsNeverFetched(draft: Bool, prerelease: Bool) async throws {
    let github = publishedGitHub()
    github.answers[latestURL] = HTTPResponse(status: 200, body: releaseJSON(draft: draft, prerelease: prerelease))
    await #expect(throws: FeedError.notPublished) { try await GitHubReleaseFeed(http: github).latest() }
    #expect(github.asked.map(\.url) == [latestURL])
}

@Test func aReleaseWithoutItsSignatureGivesNothing() async throws {
    let github = publishedGitHub()
    github.answers[latestURL] = HTTPResponse(status: 200, body: releaseJSON(assets: ["manifest.json", "catalog.json"]))
    await #expect(throws: FeedError.missingAsset("manifest.sig")) { try await GitHubReleaseFeed(http: github).latest() }
}

/// GitHub can't be reached, answers with an error, or with something that isn't a release: the fetch is "unreachable",
/// and the firmware built into the app stays in use.
@Test(arguments: ["release 404", "release 500", "release timeout", "release not JSON", "asset 403", "asset timeout"])
func anythingWrongTalkingToGitHubIsUnreachableAndTheBuiltInStays(_ fault: String) async throws {
    let github = publishedGitHub()
    let stored = "https://objects.githubusercontent.com/github-production-release-asset/manifest.sig?sig=x"
    switch fault {
    case "release 404": github.answers[latestURL] = HTTPResponse(status: 404, body: Data())
    case "release 500": github.answers[latestURL] = HTTPResponse(status: 500, body: Data())
    case "release timeout": github.timingOut = [latestURL]
    case "release not JSON": github.answers[latestURL] = HTTPResponse(status: 200, body: Data("<html>".utf8))
    case "asset 403": github.answers[stored] = HTTPResponse(status: 403, body: Data())
    default: github.timingOut = [stored]
    }
    let builtIn = try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa")
    let outcome = await ReleaseFetcher(feed: GitHubReleaseFeed(http: github), trusting: ReleaseKeys.trusted, cache: temporaryFolder())
        .fetch(over: builtIn)
    #expect(outcome.refusal == .unreachable, "\(fault)")
    #expect(outcome.catalog.newestPanel()?.version == FirmwareVersion("1.0.0"))
}

/// Until the owner adds their keys (docs/FIRMWARE-RELEASE-SIGNING.md), the app trusts none: a release that reaches it
/// whole is refused as signed with a key it doesn't know.
@Test func withTheAppsKeysStillEmptyEveryReleaseIsAnUnknownKey() async throws {
    let github = publishedGitHub()
    serve("manifest.json", Data(#"{"format": 1, "key": "primary", "lowest_allowed": {}, "catalog": {}, "files": []}"#.utf8), on: github)
    let outcome = await ReleaseFetcher(feed: GitHubReleaseFeed(http: github), trusting: ReleaseKeys.trusted, cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .unknownKey("primary"))
}
