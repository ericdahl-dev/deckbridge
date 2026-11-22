import FirmwareRelease
import Foundation

/// The release feed's HTTP (#704): one GET, its redirect handed back to the feed rather than followed, so the feed's
/// own rule decides where a fetch may go (GitHubReleaseFeed). An ephemeral session: no cookies, no cache, nothing kept
/// between launches. Only the headers the feed passes are sent; it holds no token.
final class URLSessionHTTP: NSObject, HTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    /// A request with no answer in this long is the network's failure: "unreachable".
    static let timeout: TimeInterval = 15

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = 4 * Self.timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return HTTPResponse(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location"), body: body)
    }

    /// Never follow: the 3xx and its Location go back to the feed.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
