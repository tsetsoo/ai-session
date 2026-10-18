#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Building server..."
cargo build --release -p todo-server

echo ""
echo "Build complete: target/release/todo-server"
echo ""
echo "Run with:"
echo "  ./target/release/todo-server"
echo "  Then point the iPhone/Mac app at http://<host>:8080"
