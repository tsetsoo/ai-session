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

    init(
        displayName: String,
        hostname: String,
        port: Int = 22,
        username: String,
        defaultPaths: [String] = [],
        cliBinaries: [AITool: String] = [:],
        id: UUID = UUID(),
        lastReachableAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.username = username
        self.privateKeyKeychainRef = id.uuidString
        self.defaultPathsJSON = Self.encode(defaultPaths, fallback: "[]")
        self.cliBinariesJSON = Self.encode(cliBinaries, fallback: "{}")
        self.lastReachableAt = lastReachableAt
    }

    var defaultPaths: [String] {
        get { Self.decode([String].self, from: defaultPathsJSON) ?? [] }
        set { defaultPathsJSON = Self.encode(newValue, fallback: "[]") }
    }

    var cliBinaries: [AITool: String] {
        get { Self.decode([AITool: String].self, from: cliBinariesJSON) ?? [:] }
        set { cliBinariesJSON = Self.encode(newValue, fallback: "{}") }
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
}
