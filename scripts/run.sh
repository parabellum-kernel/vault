#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export PATH="/opt/zig:/usr/local/bin:$PATH"

ENGINE_BIN="${PARABELLUM_ENGINE_BIN:-$VAULT_ROOT/../engine/zig-out/bin/parabellum}"
PIPELINE="${PIPELINE_PATH:-$VAULT_ROOT/configs/pipeline.yaml}"

cd "$VAULT_ROOT"

echo "==> Building Vault plugin & TUI..."
zig build

chmod 755 "$VAULT_ROOT"/zig-out/lib/*.so 2>/dev/null || true

CMD="${1:-run}"
if [[ "$CMD" == "serve" || "$CMD" == "-s" || "$CMD" == "--serve" ]]; then
    shift || true
    echo "==> Starting Parabellum server on 127.0.0.1:8787 with '$PIPELINE'..."
    exec "$ENGINE_BIN" serve --transport http --listen 127.0.0.1:8787 --pipeline "$PIPELINE" "$@"
elif [[ "$CMD" == "validate" || "$CMD" == "-v" || "$CMD" == "--validate" ]]; then
    shift || true
    echo "==> Validating pipeline '$PIPELINE'..."
    exec "$ENGINE_BIN" validate "$PIPELINE" "$@"
elif [[ "$CMD" == "run" ]]; then
    shift || true
    echo "==> Running Parabellum pipeline '$PIPELINE'..."
    exec "$ENGINE_BIN" run "$PIPELINE" "$@"
else
    exec "$ENGINE_BIN" run "$@"
fi
