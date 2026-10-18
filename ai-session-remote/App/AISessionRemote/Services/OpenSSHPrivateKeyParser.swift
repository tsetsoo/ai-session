import Crypto
import Foundation
import NIOSSH

enum OpenSSHPrivateKeyParserError: Error, Equatable {
    case invalidPEM
    case encryptedKeyUnsupported
    case unsupportedFormat
    case unsupportedKeyType(String)
    case truncated
    case checkIntMismatch
}

/// Parses the `openssh-key-v1` private key format written by `ssh-keygen` (the default since
/// OpenSSH 7.8) into a `NIOSSHPrivateKey`.
///
/// `swift-nio-ssh` has no OpenSSH/PEM parser of its own — CryptoKit can't decrypt
/// passphrase-protected keys, so upstream deliberately only exposes raw-key initializers
/// (see apple/swift-nio-ssh#94). This type fills that gap for the common case: unencrypted
/// Ed25519 and ECDSA (P256/P384/P521) keys. RSA keys and passphrase-protected keys are
/// rejected with a specific error rather than failing later with a confusing auth error.
enum OpenSSHPrivateKeyParser {
    static func parse(pem data: Data) throws -> NIOSSHPrivateKey {
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenSSHPrivateKeyParserError.invalidPEM
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard
            let beginIndex = lines.firstIndex(where: { $0.contains("BEGIN OPENSSH PRIVATE KEY") }),
            let endIndex = lines.firstIndex(where: { $0.contains("END OPENSSH PRIVATE KEY") }),
            beginIndex < endIndex
        else {
            throw OpenSSHPrivateKeyParserError.invalidPEM
        }
        let base64 = lines[(beginIndex + 1)..<endIndex].joined()
        guard let raw = Data(base64Encoded: base64) else {
            throw OpenSSHPrivateKeyParserError.invalidPEM
        }

        var reader = WireReader(raw)
        let magic = try reader.readBytes(15)
        guard String(decoding: magic.dropLast(), as: UTF8.self) == "openssh-key-v1" else {
            throw OpenSSHPrivateKeyParserError.invalidPEM
        }

        let cipherName = try reader.readOpenSSHString()
        let kdfName = try reader.readOpenSSHString()
        _ = try reader.readBytesPrefixed() // kdfoptions
        guard cipherName == "none", kdfName == "none" else {
            throw OpenSSHPrivateKeyParserError.encryptedKeyUnsupported
        }

        let numKeys = try reader.readUInt32()
        guard numKeys == 1 else {
            throw OpenSSHPrivateKeyParserError.unsupportedFormat
        }

        _ = try reader.readBytesPrefixed() // public key blob (redundant with the private section)
        let privateSection = try reader.readBytesPrefixed()

        var privateReader = WireReader(Data(privateSection))
        let check1 = try privateReader.readUInt32()
        let check2 = try privateReader.readUInt32()
        guard check1 == check2 else {
            throw OpenSSHPrivateKeyParserError.checkIntMismatch
        }

        let keyType = try privateReader.readOpenSSHString()

        switch keyType {
        case "ssh-ed25519":
            _ = try privateReader.readBytesPrefixed() // public key (32 bytes)
            let priv = try privateReader.readBytesPrefixed() // seed(32) || public key(32)
            guard priv.count == 64 else { throw OpenSSHPrivateKeyParserError.truncated }
            let seed = Data(priv.prefix(32))
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))

        case "ecdsa-sha2-nistp256":
            let scalar = try Self.readECDSAScalar(&privateReader, length: 32)
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: scalar))

        case "ecdsa-sha2-nistp384":
            let scalar = try Self.readECDSAScalar(&privateReader, length: 48)
            return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: scalar))

        case "ecdsa-sha2-nistp521":
            let scalar = try Self.readECDSAScalar(&privateReader, length: 66)
            return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: scalar))

        default:
            throw OpenSSHPrivateKeyParserError.unsupportedKeyType(keyType)
        }
    }

    private static func readECDSAScalar(_ reader: inout WireReader, length: Int) throws -> Data {
        _ = try reader.readBytesPrefixed() // curve name
        _ = try reader.readBytesPrefixed() // public point
        let mpint = try reader.readBytesPrefixed() // private scalar, SSH "mpint" encoding
        return normalize(mpint, to: length)
    }

    /// SSH `mpint`s may carry a leading zero byte (to keep the value positive) or be shorter
    /// than the curve's scalar width; CryptoKit's raw initializers require an exact fixed width.
    private static func normalize(_ bytes: [UInt8], to length: Int) -> Data {
        var trimmed = bytes
        while trimmed.count > length, trimmed.first == 0 {
            trimmed.removeFirst()
        }
        if trimmed.count < length {
            trimmed = Array(repeating: 0, count: length - trimmed.count) + trimmed
        }
        return Data(trimmed)
    }
}

/// Minimal big-endian reader for the SSH binary wire format used inside OpenSSH key files.
private struct WireReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        self.bytes = Array(data)
    }

    mutating func readUInt32() throws -> UInt32 {
        let slice = try readBytes(4)
        return slice.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else {
            throw OpenSSHPrivateKeyParserError.truncated
        }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    /// Reads an SSH "string": a `uint32` length prefix followed by that many raw bytes.
    mutating func readBytesPrefixed() throws -> [UInt8] {
        let length = try readUInt32()
        return try readBytes(Int(length))
    }

    /// Reads an SSH string and interprets it as UTF-8 text (used for names/identifiers).
    mutating func readOpenSSHString() throws -> String {
        String(decoding: try readBytesPrefixed(), as: UTF8.self)
    }
}
