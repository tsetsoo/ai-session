import AISessionCore
import Foundation
import XCTest

/// Runs each command the way sshd does: the login shell gets it as one `-c` argument.
private struct LocalShell: SSHExecuting {
    let shell: String

    func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return SSHExecResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }
}

final class PhotoUploadTests: XCTestCase {
    private let config = HostConnectionConfig(host: "example", port: 22, username: "me", privateKeyPEM: Data())
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("photo-upload-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func photo(bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) })
    }

    private var quotedDir: String { "'\(dir.path)'" }

    func testEveryCommandFitsInOneLinuxArgument() {
        let commands = PhotoUpload.commands(data: photo(bytes: 600_000), name: "a.jpg")
        XCTAssertGreaterThan(commands.count, 3)
        for command in commands { XCTAssertLessThan(command.utf8.count, 128 * 1024) }
    }

    func testRoundTripsWhateverTheLoginShell() async throws {
        // sshd runs the command with the login shell; the script itself always runs under sh.
        for shell in ["/bin/sh", "/bin/zsh", "/bin/csh"] where FileManager.default.isExecutableFile(atPath: shell) {
            let data = photo(bytes: 300_000)
            let name = "\(UUID().uuidString.lowercased()).jpg"
            let path = try await PhotoUpload.upload(
                data, name: name, config: config, ssh: LocalShell(shell: shell), directory: quotedDir
            )
            XCTAssertTrue(path.hasSuffix("/\(name)"), shell)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data, shell)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, shell)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".b64"), shell)
        }
    }

    func testThePathIsTheLastLineAfterShellStartupOutput() async throws {
        let base = LocalShell(shell: "/bin/sh")
        let noisy = PrefixedOutput(base: base, prefix: "Welcome to the computer\n")
        let path = try await PhotoUpload.upload(
            photo(bytes: 100), name: "noisy.jpg", config: config, ssh: noisy, directory: quotedDir
        )
        XCTAssertTrue(path.hasPrefix("/") && path.hasSuffix("/noisy.jpg"))
    }

    func testTheDeleteRunsOnlyOnceTheMessageIsSent() async throws {
        let shell = LocalShell(shell: "/bin/sh")
        let path = try await PhotoUpload.upload(
            photo(bytes: 1000), name: "soon.jpg", config: config, ssh: shell, directory: quotedDir
        )
        XCTAssertFalse(PhotoUpload.commands(data: Data([1]), name: "a.jpg").joined().contains("sleep"), "no timer before the send")

        _ = try await shell.exec(config, command: PhotoUpload.deleteCommand(paths: [path], keepSeconds: 1))
        for _ in 0..<30 where FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testAFailedCommandStopsTheUploadAndCleansUp() async throws {
        let ssh = FakeSSHExecutor(defaultResult: SSHExecResult(exitCode: 1, stdout: "", stderr: "disk full"))
        do {
            _ = try await PhotoUpload.upload(photo(bytes: 10), name: "x.jpg", config: config, ssh: ssh)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? PhotoUpload.Failure, .failed("disk full"))
        }
        for _ in 0..<20 where ssh.recordedCommands.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(ssh.recordedCommands.count, 2)
        XCTAssertTrue(ssh.recordedCommands[1].contains("rm -f"))
    }

    func testFindsTheUploadsAMessageMentions() {
        let uploaded = ["/u/a.jpg", "/u/b.jpg"]
        XCTAssertEqual(PhotoUpload.paths(in: "look at /u/b.jpg please", from: uploaded), ["/u/b.jpg"])
    }
}

/// A login shell whose startup prints a line before the command's own output.
private struct PrefixedOutput: SSHExecuting {
    let base: SSHExecuting
    let prefix: String

    func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult {
        var result = try await base.exec(config, command: command)
        result.stdout = prefix + result.stdout
        return result
    }
}
