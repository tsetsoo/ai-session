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

    func testRoundTripsThroughShAndZsh() async throws {
        for shell in ["/bin/sh", "/bin/zsh"] {
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

    func testDeletesTheUploadAfterItsTime() async throws {
        let path = try await PhotoUpload.upload(
            photo(bytes: 1000), name: "soon.jpg", config: config, ssh: LocalShell(shell: "/bin/sh"),
            directory: quotedDir, keepSeconds: 1
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testAFailedCommandStopsTheUpload() async throws {
        let ssh = FakeSSHExecutor(defaultResult: SSHExecResult(exitCode: 1, stdout: "", stderr: "disk full"))
        do {
            _ = try await PhotoUpload.upload(photo(bytes: 10), name: "x.jpg", config: config, ssh: ssh)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? PhotoUpload.Failure, .failed("disk full"))
        }
        XCTAssertEqual(ssh.recordedCommands.count, 1)
    }
}
