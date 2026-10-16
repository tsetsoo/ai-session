#if os(macOS)
import Foundation
import SwiftData
import SwiftUI

/// Adds hosts from launch arguments, so a Mac can be set up without clicking through the
/// host editor:
///
///     open -a "AI Session Remote" --args \
///       --add-host "codbex" tsetso@100.107.204.56 ~/.ssh/id_ed25519_aisession \
///       --add-host "this Mac" me@100.103.53.126:22 ~/.ssh/id_ed25519_aisession
///
/// Each host goes through `HostRepository`, so the key lands in the app's own Keychain item
/// exactly as if it had been chosen in the editor. A host that already exists (same user,
/// hostname and port) gets its key replaced instead of being duplicated. Results are printed
/// to stderr.
///
/// This is a one-shot command: the app adds the hosts and exits before showing a window.
/// (AppKit treats the extra non-flag arguments as files to open and would skip creating the
/// normal window anyway.) Launch the app normally afterwards.
enum HostProvisioning {
    /// Call from `App.init()`. Does nothing unless `--add-host` is among the arguments.
    @MainActor
    static func runFromCommandLineIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--add-host") else { return }
        do {
            let container = try ModelContainer(for: HostEntity.self)
            run(arguments: arguments, modelContext: container.mainContext)
            exit(0)
        } catch {
            log("provisioning: could not open the host store: \(error.localizedDescription)")
            exit(1)
        }
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
            let keyPath = (arguments[index + 3] as NSString).expandingTildeInPath
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
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
#endif
