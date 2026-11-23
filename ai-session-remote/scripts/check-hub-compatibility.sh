#!/usr/bin/env bash
# Check real hub responses against the most recent shipped Mac baseline.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
baseline=2546175f817c6dabc7b2307d59338b9644b534e2
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/responses"
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation

let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func check<T: Decodable>(_ name: String, as _: T.Type) throws {
    do {
        let data = try Data(contentsOf: folder.appendingPathComponent(name + ".json"))
        guard try !decoder.decode([T].self, from: data).isEmpty else { fatalError("Empty response for /api/\(name)") }
    } catch {
        FileHandle.standardError.write(Data("/api/\(name): \(error)\n".utf8))
        exit(1)
    }
}

for prefix in ["", "scoped-"] {
    try check(prefix + "todos", as: Todo.self)
    try check(prefix + "computers", as: Computer.self)
    try check(prefix + "conversations", as: Conversation.self)
    try check(prefix + "projects", as: Project.self)
}
SWIFT
(
  cd "$root/todo-app"
  export MAC_COMPATIBILITY_RESPONSES="$scratch/responses"
  cargo test -p todo-server export_mac_compatibility_responses
  cargo test -p todo-server scoped_token_filters_real_routes_and_blocks_other_access
)

# Keep the supported floor even after releasing newer clients.
set -- "$baseline"
if [[ -n "${MAC_COMPATIBILITY_BASELINE:-}" && "$MAC_COMPATIBILITY_BASELINE" != "$baseline" ]]; then
  set -- "$@" "$MAC_COMPATIBILITY_BASELINE"
fi
prefix=ai-session-remote/Sources/AISessionCore
for revision in "$@"; do
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]]
  for source in TodoHub/TodoHubModels.swift TodoHub/ProjectModels.swift TodoHub/MCPServers.swift Push/ApsEnvironment.swift; do
    git -C "$root" show "$revision:$prefix/$source" > "$scratch/${source##*/}"
  done
  swiftc -module-cache-path "$scratch/modules" "$scratch/"*.swift -o "$scratch/check"
  "$scratch/check" "$scratch/responses"
  echo "Hub responses match the Mac app at $revision"
done
