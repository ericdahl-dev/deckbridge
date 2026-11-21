import Foundation

/// A release's manifest (ADR 0012): the release's catalog, each file's device, version, size and SHA-256, the lowest
/// version a device may go back to, and which key signed it. Only these bytes are signed; the files are hashed.
struct Manifest: Decodable {
    struct File: Decodable {
        let name: String
        let device: String
        let version: String
        let size: Int
        let sha256: String
    }

    let format: Int
    let key: String
    let lowestAllowed: [String: String]
    let files: [File]

    enum CodingKeys: String, CodingKey {
        case format, key, files
        case lowestAllowed = "lowest_allowed"
    }

    /// The manifest's "catalog" object, as raw JSON: written out as the fetched release's catalog.json.
    static func catalogJSON(in manifest: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        return try JSONSerialization.data(withJSONObject: object?["catalog"] ?? [:], options: [.sortedKeys])
    }
}
