#if os(macOS)
import AppKit
import CryptoKit
import Darwin
import Security
import ServiceManagement
import SwiftUI
import os

struct MacAppUpdateCommand: View {
    @State private var checking = false

    var body: some View {
        Button(checking ? "Checking for Updates…" : "Check for Updates…") {
            checking = true
            Task { await check() }
        }
        .disabled(checking)
        Button("Automatic Updates…") { configureAutomaticUpdates() }
    }

    @MainActor
    private func configureAutomaticUpdates() {
        guard MacAppUpdater.isInstalledCopy else {
            show("Automatic Updates", detail: "Open the copy in your home Applications folder to enable automatic updates.")
            return
        }
        let service = MacAppUpdater.automaticUpdatesService
        let alert = NSAlert()
        alert.messageText = "Automatic Updates"
        switch service.status {
        case .enabled:
            alert.informativeText = "AI Session Remote checks for updates every 15 minutes and installs them when the app is closed."
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Turn Off")
            if alert.runModal() == .alertSecondButtonReturn {
                do { try service.unregister() }
                catch { show("Couldn’t Turn Off Automatic Updates", detail: error.localizedDescription) }
            }
        case .requiresApproval:
            alert.informativeText = "Allow AI Session Remote to run in the background in System Settings."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
        default:
            alert.informativeText = "Check every 15 minutes and install verified updates when the app is closed."
            alert.addButton(withTitle: "Turn On")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do { try service.register() }
            catch {
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                else { show("Couldn’t Turn On Automatic Updates", detail: error.localizedDescription) }
            }
        }
    }

    @MainActor
    private func check() async {
        defer { checking = false }
        do {
            guard MacAppUpdater.isInstalledCopy else {
                throw MacAppUpdater.Failure("Open the copy in your home Applications folder to update it.")
            }
            let update = try await Task.detached(priority: .userInitiated) {
                try await MacAppUpdater.prepare()
            }.value
            guard let update else {
                show("You’re up to date", detail: "There is no newer published build for this installation.")
                return
            }

            var handedOff = false
            defer { if !handedOff { update.remove() } }
            let alert = NSAlert()
            alert.messageText = "An update is ready"
            alert.informativeText = "AI Session Remote will quit, install the update, and reopen."
            alert.addButton(withTitle: "Install and Restart")
            alert.addButton(withTitle: "Later")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let pid = ProcessInfo.processInfo.processIdentifier
            try await Task.detached(priority: .userInitiated) {
                try MacAppUpdater.startInstaller(update: update, waitingFor: pid)
            }.value
            handedOff = true
            NSApp.terminate(nil)
        } catch {
            show("Couldn’t Update AI Session Remote", detail: error.localizedDescription)
        }
    }

    @MainActor
    private func show(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}

enum MacAppUpdater {
    private static let files = FileManager.default
    private static let appName = "AI Session Remote.app"
    private static let bundleID = "com.aisessionremote.mac"
    private static let applications = files.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    private static let destination = applications.appendingPathComponent(appName)
    private static let stamp = applications.appendingPathComponent(".ai-session-remote-commit")
    private static let support = files.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AI Session Remote Updater")
    private static let lock = support.appendingPathComponent("update.lock")
    private static let release = URL(string: "https://api.github.com/repos/tsetsoo/ai-session/releases/tags/mac-latest")!
    private static let downloads = URL(string: "https://github.com/tsetsoo/ai-session/releases/download/mac-latest/")!

    private struct Release: Decodable {
        let body: String
    }

    private struct Manifest: Decodable {
        let revision: String
        let sha256: String
    }
    private static let requirement = """
    identifier "com.aisessionremote.mac" and anchor apple generic and certificate leaf[subject.OU] = "233QTK6KCL" and certificate leaf[subject.CN] = "Apple Development:"*
    """
    private static let log = Logger(subsystem: bundleID, category: "AppUpdater")

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct Prepared: Sendable {
        let directory: URL
        let revision: String
        let previousRevision: String

        var bundle: URL { directory.appendingPathComponent(MacAppUpdater.appName) }
        var preserve: URL { directory.appendingPathComponent("preserve-rollback") }
        func remove() {
            guard !FileManager.default.fileExists(atPath: preserve.path) else { return }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static var automaticUpdatesService: SMAppService {
        SMAppService.agent(plistName: "com.aisessionremote.mac-updater.plist")
    }

    static var isInstalledCopy: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath()
    }

    static func runFromCommandLineIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "--enable-automatic-app-updates", "--automatic-app-updates-status":
            guard isInstalledCopy else {
                FileHandle.standardError.write(Data("Run this command from the installed Mac app.\n".utf8))
                exit(EXIT_FAILURE)
            }
            let service = automaticUpdatesService
            if args.first == "--enable-automatic-app-updates",
               service.status != .enabled, service.status != .requiresApproval {
                do { try service.register() }
                catch where service.status == .requiresApproval { }
                catch {
                    let registrationError = error as NSError
                    let message = "\(registrationError.localizedDescription) (\(registrationError.domain) \(registrationError.code))\n"
                    FileHandle.standardError.write(Data(message.utf8))
                    exit(EXIT_FAILURE)
                }
            }
            switch service.status {
            case .enabled:
                print("Automatic updates enabled")
                exit(EXIT_SUCCESS)
            case .requiresApproval:
                print("Automatic updates require approval in System Settings → Login Items")
                exit(2)
            default:
                print("Automatic updates are off (Service Management status \(service.status.rawValue))")
                exit(3)
            }
        case "--install-app-update":
            do {
                try installAfterExit(args)
                exit(EXIT_SUCCESS)
            } catch {
                log.error("\(error.localizedDescription, privacy: .public)")
                exit(EXIT_FAILURE)
            }
        case "--install-fleet-app-update":
            do {
                try installFleetBuild(args)
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(EXIT_FAILURE)
            }
        case "--background-app-update":
            Task.detached {
                do {
                    try await backgroundUpdate()
                    exit(EXIT_SUCCESS)
                } catch {
                    log.error("\(error.localizedDescription, privacy: .public)")
                    exit(EXIT_FAILURE)
                }
            }
            dispatchMain()
        default:
            return
        }
    }

    static func prepare(skipRejected: Bool = false) async throws -> Prepared? {
        let installed = try installedRevision()
        let (data, response) = try await URLSession.shared.data(for: request(release))
        try check(response, missing: "No Mac release has been published yet.")
        let manifest: Manifest
        do {
            let releaseInfo = try JSONDecoder().decode(Release.self, from: data)
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(releaseInfo.body.utf8))
        } catch {
            throw Failure("The published Mac release has an invalid update manifest.")
        }
        let revision = manifest.revision
        guard validRevision(revision), validHex(manifest.sha256, length: 64) else {
            throw Failure("The published Mac release has an invalid revision or archive checksum.")
        }
        guard revision != installed else { return nil }
        if skipRejected,
           (try? String(contentsOf: support.appendingPathComponent("rejected-revision"), encoding: .utf8)) == revision {
            return nil
        }
        if !installed.isEmpty {
            let compare = URL(string: "https://api.github.com/repos/tsetsoo/ai-session/compare/\(installed)...\(revision)?per_page=1")!
            let (comparison, response) = try await URLSession.shared.data(for: request(compare))
            try check(response, missing: "GitHub cannot compare this local build to the published release.")
            struct Comparison: Decodable { let status: String }
            guard try JSONDecoder().decode(Comparison.self, from: comparison).status == "ahead" else { return nil }
        }

        let directory = applications.appendingPathComponent(".ai-session-remote-update.\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let update = Prepared(directory: directory, revision: revision, previousRevision: installed)
        do {
            let archiveURL = downloads.appendingPathComponent("ai-session-remote-mac-\(revision)-\(manifest.sha256).zip")
            let (download, response) = try await URLSession.shared.download(for: request(archiveURL))
            try check(response)
            guard try sha256(of: download) == manifest.sha256 else {
                throw Failure("The downloaded update failed its checksum. Check again.")
            }
            try run("/usr/bin/ditto", ["-x", "-k", download.path, directory.path])
            try verify(update)
            return update
        } catch {
            update.remove()
            throw error
        }
    }

    static func startInstaller(update: Prepared, waitingFor pid: Int32) throws {
        guard let executable = Bundle.main.executableURL else { throw Failure("The app executable is missing.") }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [
            "--install-app-update", update.directory.lastPathComponent,
            update.revision, update.previousRevision, String(pid)
        ]
        process.standardOutput = output
        try process.run()
        let ready = Data("ready\n".utf8)
        guard output.fileHandleForReading.readData(ofLength: ready.count) == ready else {
            throw Failure("The installer could not start. Try checking for updates again.")
        }
    }

    private static func preparedUpdate(_ args: [String]) throws -> Prepared {
        let prefix = ".ai-session-remote-update."
        guard args.count >= 4, validRevision(args[2]), args[3].isEmpty || validRevision(args[3]),
              args[1].hasPrefix(prefix),
              UUID(uuidString: String(args[1].dropFirst(prefix.count))) != nil else {
            throw Failure("Invalid update installer arguments.")
        }
        return Prepared(directory: applications.appendingPathComponent(args[1]),
                        revision: args[2], previousRevision: args[3])
    }

    private static func installAfterExit(_ args: [String]) throws {
        guard isInstalledCopy, args.count == 5, let pid = Int32(args[4]), pid > 1 else {
            throw Failure("Invalid restart installer arguments.")
        }
        let update = try preparedUpdate(args)
        defer { update.remove() }
        try acquireLock()
        defer { try? files.removeItem(at: lock) }
        try checkCandidate(update)
        FileHandle.standardOutput.write(Data("ready\n".utf8))

        guard wait(seconds: 30, until: { kill(pid, 0) != 0 && errno == ESRCH }) else {
            throw Failure("The app did not quit in time.")
        }
        try installAndValidate(update, keepRunning: true)
    }

    private static func installFleetBuild(_ args: [String]) throws {
        let update = try preparedUpdate(args)
        guard args.count == 4,
              Bundle.main.bundleURL.resolvingSymlinksInPath() == update.bundle.resolvingSymlinksInPath() else {
            throw Failure("Run the fleet installer from the staged signed app.")
        }
        try acquireLock()
        defer { try? files.removeItem(at: lock) }
        try checkCandidate(update)
        let running = runningApps()
        for app in running { _ = app.terminate() }
        guard wait(seconds: 20, until: { runningApps().isEmpty }) else {
            throw Failure("AI Session Remote did not quit in time.")
        }
        try installAndValidate(update, keepRunning: !running.isEmpty)
        print(running.isEmpty ? "Launch confirmed (background check)" : "App reopened and confirmed launch")
    }

    private static func backgroundUpdate() async throws {
        guard isInstalledCopy, runningApps().isEmpty else { return }
        try acquireLock()
        defer { try? files.removeItem(at: lock) }
        guard let update = try await prepare(skipRejected: true) else { return }
        defer { update.remove() }
        guard runningApps().isEmpty else { return }
        try installAndValidate(update, keepRunning: false)
    }

    private static func installAndValidate(_ update: Prepared, keepRunning: Bool) throws {
        var swapped = false
        var trialPID: pid_t?
        let token = UUID().uuidString
        let receipt = support.appendingPathComponent("launch-\(token)")
        defer { try? files.removeItem(at: receipt) }
        do {
            try checkCandidate(update)
            guard runningApps().isEmpty else { throw Failure("Quit AI Session Remote before installing the update.") }
            // Preserve the previous bundle if the installer itself is interrupted after the swap.
            try Data().write(to: update.preserve, options: .atomic)
            do { try exchange(update.bundle, destination) }
            catch {
                try? files.removeItem(at: update.preserve)
                throw error
            }
            swapped = true
            let options = keepRunning ? ["-n"] : ["-n", "-g", "-j"]
            try run("/usr/bin/open", options + [destination.path, "--args", "--confirm-app-update", token])
            guard wait(seconds: 30, until: {
                guard let text = try? String(contentsOf: receipt, encoding: .utf8) else { return false }
                let fields = text.split(separator: " ")
                guard fields.count == 2, fields[1] == update.revision, let pid = Int32(fields[0]),
                      kill(pid, 0) == 0 else { return false }
                trialPID = pid
                return true
            }), let trialPID else {
                throw Failure("The updated app did not confirm that it finished launching.")
            }
            // Give an immediate startup crash time to surface before committing the update.
            Thread.sleep(forTimeInterval: 1)
            guard kill(trialPID, 0) == 0 else { throw Failure("The updated app exited during launch.") }
            if !keepRunning, let app = NSRunningApplication(processIdentifier: trialPID) {
                _ = app.terminate()
                _ = wait(seconds: 5, until: { kill(trialPID, 0) != 0 })
            }
        } catch {
            if swapped {
                let running = runningApps()
                for app in running { _ = app.forceTerminate() }
                guard wait(seconds: 10, until: { runningApps().isEmpty }) else {
                    throw Failure("Could not stop the failed update. The previous app is at \(update.bundle.path).")
                }
                do { try exchange(update.bundle, destination) }
                catch { throw Failure("Could not restore the previous build. It is at \(update.bundle.path).") }
                try? files.removeItem(at: update.preserve)
                try? update.revision.write(to: support.appendingPathComponent("rejected-revision"), atomically: true, encoding: .utf8)
            }
            if keepRunning, runningApps().isEmpty { try? run("/usr/bin/open", [destination.path]) }
            if swapped { throw Failure("Restored the previous build. \(error.localizedDescription)") }
            throw error
        }

        // The signed app carries its revision even if writing the legacy stamp fails.
        do {
            let previous = support.appendingPathComponent("previous.app")
            if files.fileExists(atPath: previous.path) { try files.removeItem(at: previous) }
            try files.moveItem(at: update.bundle, to: previous)
            try files.removeItem(at: update.preserve)
            try (update.revision + "\n").write(to: stamp, atomically: true, encoding: .utf8)
            try? files.removeItem(at: support.appendingPathComponent("rejected-revision"))
        } catch {
            log.error("Installed the update but could not save rollback metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func observeLaunch() {
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                               object: nil, queue: .main) { _ in
            recordLaunch()
        }
    }

    private static func recordLaunch() {
        guard isInstalledCopy, let revision = try? installedRevision(), validRevision(revision) else { return }
        do {
            try files.createDirectory(at: support, withIntermediateDirectories: true)
            let pid = ProcessInfo.processInfo.processIdentifier
            let state = "\(pid) \(revision)"
            try state.write(to: support.appendingPathComponent("running-build"), atomically: true, encoding: .utf8)
            let args = CommandLine.arguments
            if let flag = args.firstIndex(of: "--confirm-app-update"), args.indices.contains(flag + 1),
               let token = UUID(uuidString: args[flag + 1]) {
                try state.write(to: support.appendingPathComponent("launch-\(token.uuidString)"), atomically: true, encoding: .utf8)
            }
        } catch {
            log.error("Could not record app startup: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func exchange(_ source: URL, _ target: URL) throws {
        guard renamex_np(source.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func wait(seconds: Int, until condition: () -> Bool) -> Bool {
        let deadline = DispatchTime.now() + .seconds(seconds)
        while !condition() {
            guard DispatchTime.now() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return true
    }

    private static func checkCandidate(_ update: Prepared) throws {
        guard try installedRevision() == update.previousRevision else {
            throw Failure("The installed app changed during the update. Check again.")
        }
        try verify(update)
    }

    private static func verify(_ update: Prepared) throws {
        var code: SecStaticCode?
        var required: SecRequirement?
        guard SecStaticCodeCreateWithPath(update.bundle as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess,
              let code, let required,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), required) == errSecSuccess else {
            throw Failure("The downloaded app did not pass Apple Development signature verification.")
        }
        guard let bundle = Bundle(url: update.bundle),
              bundle.object(forInfoDictionaryKey: "AISessionReleaseRevision") as? String == update.revision else {
            throw Failure("The release changed during download. Check again.")
        }
        #if arch(arm64)
        let architecture = CPU_TYPE_ARM64
        #else
        let architecture = CPU_TYPE_X86_64
        #endif
        guard bundle.executableArchitectures?.contains(NSNumber(value: architecture)) == true else {
            throw Failure("The downloaded app cannot run on this Mac.")
        }
    }

    private static func installedRevision() throws -> String {
        let signed = Bundle(url: destination)?.object(forInfoDictionaryKey: "AISessionReleaseRevision") as? String
        let stored = (try? String(contentsOf: stamp, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = signed.flatMap { $0.isEmpty ? nil : $0 } ?? stored ?? ""
        guard revision.isEmpty || validRevision(revision) else { throw Failure("The installed build has an invalid revision.") }
        return revision
    }

    private static func validRevision(_ revision: String) -> Bool { validHex(revision, length: 40) }

    private static func validHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var checksum = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            checksum.update(data: chunk)
        }
        return checksum.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func runningApps() -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            !$0.isTerminated && $0.processIdentifier != ownPID && kill($0.processIdentifier, 0) == 0
                && $0.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath()
        }
    }

    private static func acquireLock() throws {
        try files.createDirectory(at: support, withIntermediateDirectories: true)
        try run("/usr/bin/shlock", ["-f", lock.path, "-p", String(ProcessInfo.processInfo.processIdentifier)],
                failure: "Another update is in progress.")
    }

    private static func request(_ url: URL) -> URLRequest { URLRequest(url: url, timeoutInterval: 120) }

    private static func check(_ response: URLResponse, missing: String? = nil) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw Failure(status == 404 ? (missing ?? "A Mac release file is missing.") : "GitHub returned HTTP \(status).")
        }
    }

    private static func run(_ executable: String, _ arguments: [String], failure: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(failure ?? "\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus)).")
        }
    }
}
#endif
