Weekly upkeep for {project}: dependency updates and security advisories.

1. Find the project's package managers (Cargo.toml, package.json, go.mod, Package.swift, requirements or pyproject, and any in subfolders).
2. For each, check what's outdated and what has advisories, with the tools that are installed:
   - Rust: `cargo update --dry-run`, `cargo audit` (if installed)
   - Node: `npm outdated`, `npm audit`
   - Go: `go list -m -u all`, `govulncheck ./...` (if installed)
   - Swift: `swift package show-dependencies`, then compare with the latest tags
   - Python: `pip list --outdated` in its environment
   Skip what isn't installed and say so.
3. Apply the safe updates: patch and minor versions, and anything that fixes an advisory. Run the project's tests after each manager's updates; keep only what passes.
4. Commit each manager's updates separately on this branch, with what changed in the message.
5. End with a short summary: what you updated, the advisories fixed, and what you left for me (major versions, breaking changes, failing tests, tools that weren't installed).

Don't do major upgrades or change code beyond what an update needs. Don't push.
