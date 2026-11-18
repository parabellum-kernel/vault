#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export PATH="/opt/zig:/usr/local/bin:$PATH"
export VAULT_URL="${VAULT_URL:-http://127.0.0.1:8787}"
export VAULT_ID="${VAULT_ID:-default}"
export PARABELLUM_PLUGIN_DIR="${PARABELLUM_PLUGIN_DIR:-$VAULT_ROOT/zig-out/lib}"

cd "$VAULT_ROOT"

if [[ ! -x "$VAULT_ROOT/zig-out/bin/vault-tui" ]]; then
    echo "==> Building vault-tui & plugin..."
    zig build
    chmod 755 "$VAULT_ROOT"/zig-out/bin/vault-tui 2>/dev/null || true
    chmod 755 "$VAULT_ROOT"/zig-out/lib/*.so 2>/dev/null || true
fi

exec "$VAULT_ROOT/zig-out/bin/vault-tui" "$@"
