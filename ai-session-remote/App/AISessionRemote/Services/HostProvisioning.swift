import Foundation
import SwiftData
import SwiftUI

/// Sets the app up from launch arguments, so it can be configured without clicking through
/// Settings and the host editor:
///
///     # Mac
///     "AI Session Remote" --hub-url http://100.118.255.23:8080 \
///       --add-host "codbex" tsetso@100.107.204.56 ~/.ssh/id_ed25519_aisession
///
///     # iPhone: copy the key into the app's data container first, then launch with a path
///     # relative to the container (the copied key file is deleted after it is imported)
///     xcrun devicectl device copy to --device <id> --domain-type appDataContainer \
///       --domain-identifier com.aisessionremote.app --source ~/.ssh/key --destination tmp/key
///     xcrun devicectl device process launch --device <id> com.aisessionremote.app \
///       --hub-url http://100.118.255.23:8080 --add-host "codbex" tsetso@100.107.204.56 tmp/key
///
/// - `--hub-url URL` saves the todo server address; `--hub-token TOKEN` saves the API token.
/// - Each host goes through `HostRepository`, so the key lands in the app's own Keychain item
///   exactly as if it had been chosen in the editor. A host that already exists (same user,
///   hostname and port) gets its key replaced instead of being duplicated.
/// - Results go to stderr and to Library/Caches/provisioning.log in the app's container.
///
/// On the Mac this is a one-shot command: the app exits before showing a window (AppKit
/// treats the extra non-flag arguments as files to open and would skip the normal window
/// anyway). On iOS the app carries on starting normally.
enum HostProvisioning {
    /// Call from `App.init()`. Does nothing unless a provisioning flag is among the arguments.
    @MainActor
    static func runFromCommandLineIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let flags: Set = ["--add-host", "--hub-url", "--hub-token"]
        guard arguments.contains(where: flags.contains) else { return }
        applyHubSettings(arguments)
        do {
            run(arguments: arguments, modelContext: HostStore.shared.mainContext)
        } catch {
            log("provisioning: could not open the host store: \(error.localizedDescription)")
            #if os(macOS)
            exit(1)
            #endif
        }
        #if os(macOS)
        exit(0)
        #endif
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.endIndex else { return nil }
        return arguments[index + 1]
    }

    @MainActor
    private static func applyHubSettings(_ arguments: [String]) {
        if let url = value(after: "--hub-url", in: arguments) {
            TodoHubSettings.baseURLString = url
            log("provisioning: hub url set to \(url)")
        }
        if let token = value(after: "--hub-token", in: arguments) {
            do {
                try TodoHubSettings.setToken(token)
                log("provisioning: hub token saved")
            } catch {
                log("provisioning: saving hub token failed: \(error.localizedDescription)")
            }
        }
    }

    /// `~` expands to the user's home; other relative paths resolve inside the app's own
    /// container (that is where `devicectl device copy to` puts files on iOS).
    static func resolveKeyPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        return (home as NSString).appendingPathComponent(path)
    }

    struct Request: Equatable {
        var displayName: String
        var username: String
        var hostname: String
        var port: Int
        var keyPath: String
    }

    enum ParseError: LocalizedError, Equatable {
        case missingValues
        case badTarget(String)

        var errorDescription: String? {
            switch self {
            case .missingValues: "--add-host needs: <name> <user@host[:port]> <key path>"
            case let .badTarget(t): "Expected user@host[:port], got \(t)"
            }
        }
    }

    static func parse(_ arguments: [String]) throws -> [Request] {
        var requests: [Request] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            defer { index += 1 }
            guard arguments[index] == "--add-host" else { continue }
            guard index + 3 < arguments.endIndex else {
                throw ParseError.missingValues
            }
            let name = arguments[index + 1]
            let target = arguments[index + 2]
            let keyPath = resolveKeyPath(arguments[index + 3])
            index += 3

            guard let at = target.firstIndex(of: "@") else { throw ParseError.badTarget(target) }
            let username = String(target[..<at])
            var hostPart = String(target[target.index(after: at)...])
            var port = 22
            if let colon = hostPart.lastIndex(of: ":"), let p = Int(hostPart[hostPart.index(after: colon)...]) {
                port = p
                hostPart = String(hostPart[..<colon])
            }
            guard !username.isEmpty, !hostPart.isEmpty else { throw ParseError.badTarget(target) }
            requests.append(Request(displayName: name, username: username, hostname: hostPart, port: port, keyPath: keyPath))
        }
        return requests
    }

    @MainActor
    static func run(arguments: [String] = ProcessInfo.processInfo.arguments, modelContext: ModelContext) {
        let requests: [Request]
        do {
            requests = try parse(arguments)
        } catch {
            log("provisioning: \(error.localizedDescription)")
            return
        }
        guard !requests.isEmpty else { return }

        let repository = HostRepository(modelContext: modelContext)
        let existing = (try? modelContext.fetch(FetchDescriptor<HostEntity>())) ?? []
        for request in requests {
            do {
                let pem = try String(contentsOfFile: request.keyPath, encoding: .utf8)
                _ = try OpenSSHPrivateKeyParser.parse(pem: Data(pem.utf8))
                if let host = existing.first(where: {
                    $0.hostname == request.hostname && $0.port == request.port && $0.username == request.username
                }) {
                    try repository.update(
                        host,
                        displayName: request.displayName,
                        hostname: request.hostname,
                        port: request.port,
                        username: request.username,
                        pem: pem,
                        defaultPaths: host.defaultPaths,
                        cliBinaries: host.cliBinaries
                    )
                    log("provisioning: updated \(request.username)@\(request.hostname):\(request.port)")
                } else {
                    try repository.create(
                        displayName: request.displayName,
                        hostname: request.hostname,
                        port: request.port,
                        username: request.username,
                        pem: pem,
                        defaultPaths: [],
                        cliBinaries: [:]
                    )
                    log("provisioning: added \(request.username)@\(request.hostname):\(request.port)")
                }
            } catch {
                log("provisioning: \(request.username)@\(request.hostname) failed: \(error.localizedDescription)")
            }
        }

        #if os(iOS)
        // On iOS a key copied into the app's own container was only a hand-over: once
        // imported it lives in the Keychain, so don't leave the private key lying around.
        // iOS only: the unsandboxed Mac app's "home" is the user's real home, so this would
        // delete the user's actual ~/.ssh keys there.
        let home = NSHomeDirectory()
        for path in Set(requests.map(\.keyPath)) where path.hasPrefix(home + "/") {
            if (try? FileManager.default.removeItem(atPath: path)) != nil {
                log("provisioning: removed copied key file \(path.dropFirst(home.count + 1))")
            }
        }
        #endif
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = caches.appendingPathComponent("provisioning.log")
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}
