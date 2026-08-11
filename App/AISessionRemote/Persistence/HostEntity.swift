import AISessionCore
import Foundation
import SwiftData

@Model
final class HostEntity {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var hostname: String
    var port: Int
    var username: String
    var privateKeyKeychainRef: String
    var defaultPathsJSON: String
    var cliBinariesJSON: String
    var lastReachableAt: Date?
    /// Last tool chosen in New Session for this host (`AITool.rawValue`).
    var preferredToolRaw: String?
    /// Last working-directory path used when starting a session.
    var lastUsedPath: String?
    /// Cached JSON for `HostBinaryHealth` from the last probe.
    var binaryHealthJSON: String?
    var binaryHealthCheckedAt: Date?

    init(
        displayName: String,
        hostname: String,
        port: Int = 22,
        username: String,
        defaultPaths: [String] = [],
        cliBinaries: [AITool: String] = [:],
        id: UUID = UUID(),
        lastReachableAt: Date? = nil,
        preferredToolRaw: String? = nil,
        lastUsedPath: String? = nil,
        binaryHealthJSON: String? = nil,
        binaryHealthCheckedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.username = username
        self.privateKeyKeychainRef = id.uuidString
        self.defaultPathsJSON = Self.encode(defaultPaths, fallback: "[]")
        self.cliBinariesJSON = Self.encodeCliBinaries(cliBinaries)
        self.lastReachableAt = lastReachableAt
        self.preferredToolRaw = preferredToolRaw
        self.lastUsedPath = lastUsedPath
        self.binaryHealthJSON = binaryHealthJSON
        self.binaryHealthCheckedAt = binaryHealthCheckedAt
    }

    var defaultPaths: [String] {
        get { Self.decode([String].self, from: defaultPathsJSON) ?? [] }
        set { defaultPathsJSON = Self.encode(newValue, fallback: "[]") }
    }

    var cliBinaries: [AITool: String] {
        get { Self.decodeCliBinaries(from: cliBinariesJSON) }
        set { cliBinariesJSON = Self.encodeCliBinaries(newValue) }
    }

    var preferredTool: AITool? {
        get { preferredToolRaw.flatMap(AITool.init(rawValue:)) }
        set { preferredToolRaw = newValue?.rawValue }
    }

    var binaryHealth: HostBinaryHealth? {
        get {
            guard let binaryHealthJSON,
                  let data = binaryHealthJSON.data(using: .utf8)
            else { return nil }
            return try? JSONDecoder().decode(HostBinaryHealth.self, from: data)
        }
        set {
            guard let newValue,
                  let data = try? JSONEncoder().encode(newValue),
                  let string = String(data: data, encoding: .utf8)
            else {
                binaryHealthJSON = nil
                return
            }
            binaryHealthJSON = string
        }
    }

    private static func encode<Value: Encodable>(_ value: Value, fallback: String) -> String {
        guard
            let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return fallback
        }
        return string
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from string: String) -> Value? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encodeCliBinaries(_ binaries: [AITool: String]) -> String {
        let rawValueBinaries = binaries.reduce(into: [String: String]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
        return encode(rawValueBinaries, fallback: "{}")
    }

    private static func decodeCliBinaries(from string: String) -> [AITool: String] {
        let rawValueBinaries = decode([String: String].self, from: string) ?? [:]
        return rawValueBinaries.reduce(into: [AITool: String]()) { result, entry in
            guard let tool = AITool(rawValue: entry.key) else { return }
            result[tool] = entry.value
        }
    }
}
