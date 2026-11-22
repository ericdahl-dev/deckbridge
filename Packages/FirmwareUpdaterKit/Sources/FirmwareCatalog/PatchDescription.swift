import Foundation

/// Reads a patch description in the flash kit's format (tools/lc6000-firmware/README.md): one edit per line,
/// `ADDRESS OLD-HEX NEW-HEX`, `#` starts a comment. The limits keep an LC6000 entry a description, never an image:
/// the kit's largest edit is 4 bytes and its longest file under 1.3 KB.
public enum PatchDescription {
    static let maxFileBytes = 8 * 1024
    static let maxEditBytes = 16
    static let maxEdits = 32

    /// The edits, or nil if the file is anything but a small patch description.
    public static func edits(_ data: Data) -> [PatchEdit]? {
        guard data.count <= maxFileBytes, let text = String(data: data, encoding: .utf8) else { return nil }
        var edits: [PatchEdit] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            if fields.isEmpty { continue }
            guard fields.count == 3, fields[0].hasPrefix("0x"), let address = UInt32(fields[0].dropFirst(2), radix: 16),
                  let old = bytes(fields[1]), let new = bytes(fields[2]), old.count == new.count else { return nil }
            edits.append(PatchEdit(address: address, old: old, new: new))
        }
        guard !edits.isEmpty, edits.count <= maxEdits else { return nil }
        return edits
    }

    private static func bytes(_ hex: Substring) -> [UInt8]? {
        let digits = Array(hex)
        guard !digits.isEmpty, digits.count % 2 == 0, digits.count / 2 <= maxEditBytes else { return nil }
        var out: [UInt8] = []
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[i...i + 1]), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }
}
