#if os(macOS)
import Darwin
import Foundation

/// Prepares the signed app's vendored archive away from the main actor. A browser
/// can be launched from several conversation windows, but each version is unpacked once.
actor BundledTerminalBrowser {
    static let shared = BundledTerminalBrowser()

    struct Installation: Sendable {
        let executable: URL
        let environment: [String]
    }

    private var runtimeDirectory: String?

    func prepare() throws -> Installation {
        let files = FileManager.default
        let resources = Bundle.main.resourceURL?.appendingPathComponent("TerminalBrowser")
        #if arch(arm64)
        let target = "darwin-arm64"
        #else
        let target = "darwin-x64"
        #endif
        guard let resources,
              let version = try? String(contentsOf: resources.appendingPathComponent("VERSION"), encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              version.wholeMatch(of: /^v[0-9]+\.[0-9]+\.[0-9]+$/) != nil else {
            throw PreparationError.missingBundle
        }
        let archive = resources.appendingPathComponent("terminal-browser-\(target).tar.gz")
        guard files.isReadableFile(atPath: archive.path) else { throw PreparationError.missingBundle }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.aisessionremote.mac"
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("TerminalBrowser", isDirectory: true)
        let distributions = try files.url(for: .cachesDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("TerminalBrowser", isDirectory: true)
        let distribution = distributions.appendingPathComponent("\(version)-\(target)", isDirectory: true)
        let executable = distribution.appendingPathComponent("bin/terminal-browser")
        if !files.isExecutableFile(atPath: executable.path) {
            try unpack(archive, to: distribution, in: distributions)
        }

        let runtime = try runtimePath()
        // Pixel also puts Unix sockets under its state directory.
        let state = URL(fileURLWithPath: runtime).appendingPathComponent("state", isDirectory: true)
        let setupDir = state.appendingPathComponent("terminal-browser", isDirectory: true)
        try files.createDirectory(at: setupDir, withIntermediateDirectories: true)
        // The pinned CLI checks this marker before its one-time editor and skill setup.
        // The app provides its own terminal and needs neither of those integrations.
        let canonicalPath = distribution.resolvingSymlinksInPath().path
        try "\(version) \(canonicalPath)\n".write(
            to: setupDir.appendingPathComponent("setup-version"), atomically: true, encoding: .utf8
        )

        return Installation(executable: executable, environment: [
            "XDG_DATA_HOME=\(support.appendingPathComponent("Data").path)",
            "XDG_STATE_HOME=\(state.path)",
            "XDG_CACHE_HOME=\(support.appendingPathComponent("Cache").path)",
            "TERMINAL_BROWSER_CONFIG_DIR=\(support.appendingPathComponent("Config").path)",
            "TERMINAL_BROWSER_APPDATA=\(support.path)",
            "XDG_RUNTIME_DIR=\(runtime)",
            "TERMINAL_BROWSER_NO_TELEMETRY=1",
            "TERMINAL_BROWSER_NO_MERGE=1"
        ])
    }

    private func unpack(_ archive: URL, to destination: URL, in parent: URL) throws {
        let files = FileManager.default
        let staging = parent.appendingPathComponent(".unpack-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "--strip-components", "1", "-C", staging.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0,
              files.isExecutableFile(atPath: staging.appendingPathComponent("bin/terminal-browser").path)
        else { throw PreparationError.extractionFailed }

        do {
            try files.moveItem(at: staging, to: destination)
        } catch {
            // Another instance of the app may have finished installing the same version.
            guard files.isExecutableFile(atPath: destination.appendingPathComponent("bin/terminal-browser").path)
            else { throw error }
        }
    }

    private func runtimePath() throws -> String {
        if let runtimeDirectory { return runtimeDirectory }
        // Keep Unix socket paths within macOS's length limit and accessible only to this user.
        var template = Array("/tmp/asr-browser.XXXXXX".utf8CString)
        guard let path = template.withUnsafeMutableBufferPointer({ buffer -> String? in
            guard let address = buffer.baseAddress, mkdtemp(address) != nil else { return nil }
            return String(cString: address)
        }) else { throw PreparationError.extractionFailed }
        runtimeDirectory = path
        return path
    }

    private enum PreparationError: LocalizedError {
        case missingBundle
        case extractionFailed

        var errorDescription: String? {
            switch self {
            case .missingBundle: "This build is missing its Terminal Browser bundle."
            case .extractionFailed: "Couldn’t prepare the bundled Terminal Browser."
            }
        }
    }
}
#endif
