// The maintainer's release signing tool (ADR 0012, #689). Run on the maintainer's Mac only, never in CI.
//
//   firmware-release new-key --id primary|backup --out <file>   make a key, sealed with a passphrase typed twice
//   firmware-release public-key <file>                          print the id and public key (hex) to build into the app
//   firmware-release sign --key <file> --folder <dir> --lowest <version>
//                                                               write <dir>/manifest.json and <dir>/manifest.sig
//
// The passphrase is read from the terminal with echo off. It is never taken from an argument, an environment
// variable or a file. A forgotten passphrase is a lost key: sign with the backup key (see the owner guide).
import Darwin
import Foundation
import FirmwareModel
import FirmwareRelease

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("firmware-release: \(message)\n".utf8))
    exit(1)
}

func passphrase(_ prompt: String) -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    guard let read = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else { fail("no terminal to read the passphrase from") }
    let text = String(cString: read)
    buffer.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) }
    return text
}

func option(_ name: String, in args: [String]) -> String {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { fail("missing \(name)") }
    return args[i + 1]
}

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "new-key":
    let id = option("--id", in: args), out = URL(filePath: option("--out", in: args))
    guard ["primary", "backup"].contains(id) else { fail("--id is primary or backup") }
    guard !FileManager.default.fileExists(atPath: out.path(percentEncoded: false)) else { fail("\(out.path) exists; not overwriting a key") }
    let first = passphrase("Passphrase for the \(id) key: ")
    guard first.count >= 12 else { fail("use a passphrase of at least 12 characters") }
    guard passphrase("Same passphrase again: ") == first else { fail("the two passphrases differ") }
    let key = SigningKey.generate(id: id)
    do {
        let file = try KeyFile.seal(key, passphrase: first)
        guard FileManager.default.createFile(atPath: out.path(percentEncoded: false), contents: file, attributes: [.posixPermissions: 0o600]) else {
            fail("couldn't write \(out.path)")
        }
    } catch { fail("couldn't seal the key: \(error)") }
    print("wrote \(out.path) (\(id)); public key \(hex(key.trusted.publicKey))")
case "public-key":
    guard args.count == 2, let data = FileManager.default.contents(atPath: args[1]) else { fail("public-key <file>") }
    do {
        let key = try KeyFile.publicKey(of: data)
        print("\(key.id) \(hex(key.publicKey))")
    } catch { fail("not a key file: \(error)") }
case "sign":
    let keyPath = option("--key", in: args), folder = URL(filePath: option("--folder", in: args))
    guard let lowest = FirmwareVersion(option("--lowest", in: args)) else { fail("--lowest is a dotted version") }
    guard let sealed = FileManager.default.contents(atPath: keyPath) else { fail("can't read \(keyPath)") }
    do {
        // Show what will be signed (versions, sizes, hashes) before asking for the passphrase.
        let manifest = try ReleaseSigner.manifest(for: folder, keyID: try KeyFile.publicKey(of: sealed).id, lowestAllowedPanel: lowest)
        FileHandle.standardError.write(manifest + Data("\n".utf8))
        let key = try KeyFile.open(sealed, passphrase: passphrase("Sign the manifest above? Passphrase for \(keyPath): "))
        try manifest.write(to: folder.appending(path: "manifest.json"))
        try key.sign(manifest).write(to: folder.appending(path: "manifest.sig"))
        print("signed with \(key.id): \(folder.appending(path: "manifest.json").path) and manifest.sig")
    } catch { fail("not signed: \(error)") }
default:
    fail("new-key | public-key | sign (see the comment at the top of main.swift)")
}
