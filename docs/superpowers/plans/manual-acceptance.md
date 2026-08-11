# Manual acceptance checklist — AI Session Remote v1

End-to-end acceptance for spec success criteria. Run on a **physical iPhone** over **Tailscale** against a real host with `sshd`, `tmux`, and the three CLIs (`claude`, `codex`, `agent`) installed.

**Prerequisites:** Tailscale on phone and host; host reachable via Tailscale IP/hostname; SSH key (Ed25519 or ECDSA PEM, unencrypted — RSA is not supported); host user with tmux and CLIs on `PATH` (or per-host CLI overrides configured).

---

## Automated verification (2026-08-10)

| Check | Result | Notes |
|-------|--------|-------|
| `swift test` (AISessionCore) | **Pass** | 37 tests, 0 failures |
| `xcodegen generate` + `xcodebuild` (iOS Simulator, iPhone 17) | **Pass** | `BUILD SUCCEEDED` |

These cover naming, metadata, tmux command builders, session discovery parsing, Keychain round-trip, SSH error messages, and OpenSSH key parsing — not live SSH/tmux on device.

---

## Manual checklist

| # | Scenario | Pass | Fail | Date | Notes |
|---|----------|:----:|:----:|------|-------|
| 1 | **Add Tailscale host + key** — Hosts → Add Host: label, Tailscale address, SSH user/port, paste private key; save; host appears in list with reachable indicator after refresh. | | | | **Blocked — needs physical device + Tailscale host.** Auto: `KeychainPrivateKeyStoreTests`, `OpenSSHPrivateKeyParserTests`, `TOFUHostKeyStoreTests`. |
| 2 | **Create Claude session in chosen cwd** — Select host → New Session → Claude, slug + working directory → create; session appears under AI Sessions; tmux name `ai/claude/<slug>`. | | | | **Blocked — needs physical device + Tailscale host.** Auto: `TmuxCommandBuilderTests`, `SessionServiceTests.testCreateAndListSession`, `SessionNameTests`. |
| 3 | **Create Codex session** — New Session → Codex; session listed; tmux name `ai/codex/<slug>`. | | | | **Blocked — needs physical device + Tailscale host.** Auto: `SessionNameTests.testDefaultBinaries` (`codex` binary). |
| 4 | **Create Cursor (`agent`) session** — New Session → Cursor; session listed; tmux name `ai/cursor/<slug>`; remote runs `agent` (default binary). | | | | **Blocked — needs physical device + Tailscale host.** Auto: `SessionNameTests.testDefaultBinaries` (`agent` for cursor). |
| 5 | **Disconnect; sessions persist after re-open + refresh** — Force-quit app; relaunch; open host → pull-to-refresh; previously created sessions still listed. | | | | **Blocked — needs physical device + Tailscale host.** Auto: `TmuxListParserTests`, `SessionServiceTests.testCreateAndListSession`. |
| 6 | **Reattach and continue** — Tap session → terminal attaches; prior output/history visible; can type and receive output; disconnect terminal and reattach later — same tmux session. | | | | **Blocked — needs physical device + Tailscale host.** Auto: `TmuxCommandBuilderTests.testAttach`. |
| 7 | **Unrelated tmux session under Other only** — On host, `tmux new -s manual-test` (non-`ai/` name); refresh in app; session appears under Other (or hidden), not in primary AI list. | | | | **Blocked — needs physical device + Tailscale host.** Auto: `TmuxListParserTests.testParseSplitsAIAndOther`, `testParseOtherFields`. |
| 8 | **Kill session from menu** — Swipe/menu → Kill on an AI session; confirm; session removed from list; tmux session gone on host (`tmux ls`). | | | | **Blocked — needs physical device + Tailscale host.** Auto: `SessionServiceTests.testKillSessionExecutesSuccessfully`, `TmuxCommandBuilderTests.testKillSession`. |
| 9 | **Plain SSH works** — Host menu → Plain SSH; interactive shell (no tmux attach); soft keys (Ctrl-C, Tab, Esc) work; can exit cleanly. | | | | **Blocked — needs physical device + Tailscale host.** No E2E auto coverage; build + unit tests only. |
| 10 | **No PEM in SwiftData / app container** — After adding a host with a key: inspect app container (Xcode → Devices → Download Container) and SwiftData store; confirm no private key PEM in plists, `.store`, or JSON — only Keychain ref (`privateKeyKeychainRef` / host UUID). | | | | **Blocked — needs physical device + Tailscale host** for container dump. Auto: `KeychainPrivateKeyStoreTests`; `HostEntity` stores Keychain ref only (code review). |

---

## Sign-off

| Role | Name | Date | Result |
|------|------|------|--------|
| Tester | | | Pending — all manual items blocked pending physical iPhone + Tailscale host run |

**Overall:** Manual E2E not run in Task 14 environment. Automated suite (37 tests) and iOS Simulator build passed on 2026-08-10.
