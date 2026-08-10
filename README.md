# AI Session Remote

An iOS app for managing remote hosts and AI coding sessions.

## Requirements

- Xcode 16 or later
- XcodeGen (`brew install xcodegen`)

## Generate and open

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
open AISessionRemote.xcodeproj
```

The project uses the local `AISessionCore` Swift package and targets iOS 17 or later.

## Build from the command line

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -scheme AISessionRemote \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build
```

## SSH (`NIOSSHClient`)

`App/AISessionRemote/Services/NIOSSHClient.swift` implements `SSHExecuting` on top of
[`apple/swift-nio-ssh`](https://github.com/apple/swift-nio-ssh).

- **Private keys**: `swift-nio-ssh` has no OpenSSH/PEM parser of its own (CryptoKit can't decrypt
  passphrase-protected keys, so upstream only exposes raw-key initializers — see
  [apple/swift-nio-ssh#94](https://github.com/apple/swift-nio-ssh/issues/94)).
  `OpenSSHPrivateKeyParser.swift` parses the `openssh-key-v1` binary format (the default output
  of `ssh-keygen` since OpenSSH 7.8) to fill that gap. Only **unencrypted Ed25519 and ECDSA
  (P256/P384/P521)** keys are supported; RSA and passphrase-protected keys are rejected with a
  clear error. Generate a compatible key with `ssh-keygen -t ed25519 -N ""`.
- **Host key trust (TOFU)**: `TOFUHostKeyStore` accepts a host's key on first connection and
  pins its SHA-256 fingerprint in `UserDefaults`, keyed by `host:port`; later connections must
  match exactly or the connection fails. This is a v1 stopgap, not a hardened implementation:
  the fingerprint map lives in `UserDefaults` (not Keychain), so it could be wiped/restored
  along with app data, and there's no UI yet to inspect or reset a stored fingerprint. A
  follow-up should move it to the Keychain and add a "forget this host" action.
- **Error mapping**: `SSHRemoteError` has no generic protocol/handshake case. Failures before
  the TCP connection is established (DNS, refused, timeout) map to `.unreachable`; anything
  that fails after TCP connects (handshake, host key rejection, user auth, channel setup) maps
  to `.authenticationFailed`. A non-zero remote exit code is not an error — `exec` always
  returns a normal `SSHExecResult`, and callers like `SessionService` decide if that's a
  failure.
- **Not yet exercised against a live host**: this was built and proved via `xcodebuild` compile
  only; no manual Tailscale-host `exec`/reachability test was run in this environment. The
  `ExecOutputHandler`/`ReachabilityProbe` flow follows the exec pattern from
  `apple/swift-nio-ssh`'s own `NIOSSHClient` example (session channel → `ExecRequest` →
  capture stdout/stderr/exit status), but should be validated against a real host before
  shipping.
