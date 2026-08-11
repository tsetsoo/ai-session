import Foundation
import NIOSSH
import XCTest

@testable import AISessionRemote

final class OpenSSHPrivateKeyParserTests: XCTestCase {
    // Fixture generated with `ssh-keygen -t ed25519 -N "" -f fixture_ed25519 -C fixture` —
    // an unencrypted, throwaway key used only to pin the parser's behavior.
    private static let ed25519PEM = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACDtbSsk4hYzctZhwgMSTNYDEr81wgAn5xYVuhfEtg/S5wAAAJAlxIljJcSJ
    YwAAAAtzc2gtZWQyNTUxOQAAACDtbSsk4hYzctZhwgMSTNYDEr81wgAn5xYVuhfEtg/S5w
    AAAECKPcrTMRISYmyaj3mfc+cLi8BY3ywf/mqJ4tZRl98yue1tKyTiFjNy1mHCAxJM1gMS
    vzXCACfnFhW6F8S2D9LnAAAAB2ZpeHR1cmUBAgMEBQY=
    -----END OPENSSH PRIVATE KEY-----
    """
    private static let ed25519ExpectedPublicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO1tKyTiFjNy1mHCAxJM1gMSvzXCACfnFhW6F8S2D9Ln"

    func testParsesEd25519KeyAndDerivesMatchingPublicKey() throws {
        let key = try OpenSSHPrivateKeyParser.parse(pem: Data(Self.ed25519PEM.utf8))
        XCTAssertEqual(String(openSSHPublicKey: key.publicKey), Self.ed25519ExpectedPublicKey)
    }

    func testRejectsMalformedPEM() {
        XCTAssertThrowsError(try OpenSSHPrivateKeyParser.parse(pem: Data("not a key".utf8))) { error in
            XCTAssertEqual(error as? OpenSSHPrivateKeyParserError, .invalidPEM)
        }
    }

    func testRejectsEncryptedKey() {
        // Well-formed `openssh-key-v1` header (cipher "aes256-ctr", kdf "bcrypt") with garbage
        // payload after it — the parser must reject based on the cipher/kdf name alone, before
        // ever trying to decrypt or read the (fake) private key section.
        let fakeEncrypted = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABABAQEBAQEBAQEBAQEBAQEB
        AAAAAQAAAAEAAAAIAAAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
        -----END OPENSSH PRIVATE KEY-----
        """
        XCTAssertThrowsError(try OpenSSHPrivateKeyParser.parse(pem: Data(fakeEncrypted.utf8))) { error in
            XCTAssertEqual(error as? OpenSSHPrivateKeyParserError, .encryptedKeyUnsupported)
        }
    }
}
