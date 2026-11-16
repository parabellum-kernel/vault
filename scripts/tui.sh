#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export PATH="/opt/zig:/usr/local/bin:$PATH"
export VAULT_URL="${VAULT_URL:-http://127.0.0.1:8787}"
export VAULT_ID="${VAULT_ID:-default}"

cd "$VAULT_ROOT"

if [[ ! -x "$VAULT_ROOT/zig-out/bin/vault-tui" ]]; then
    echo "Building vault-tui..."
    zig build
fi

exec "$VAULT_ROOT/zig-out/bin/vault-tui" "$@"
