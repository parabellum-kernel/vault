#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export PATH="/opt/zig:/usr/local/bin:$PATH"

# Ensure plugin directory points to vault's locally compiled drivers & extensions
export PARABELLUM_PLUGIN_DIR="${PARABELLUM_PLUGIN_DIR:-$VAULT_ROOT/zig-out/lib}"

ENGINE_BIN="${PARABELLUM_ENGINE_BIN:-$VAULT_ROOT/../engine/zig-out/bin/parabellum-engine}"
PIPELINE="${PIPELINE_PATH:-$VAULT_ROOT/configs/pipeline.yaml}"

cd "$VAULT_ROOT"

# Build external drivers (lib-gdrive-vfs, driver/sqlite, driver/yaml, etc.)
if [ -f "$SCRIPT_DIR/build.sh" ]; then
    echo "==> Building external drivers & dependencies..."
    "$SCRIPT_DIR/build.sh"
elif [ -f "$SCRIPT_DIR/build-gdrive.sh" ]; then
    echo "==> Building external drivers & dependencies..."
    "$SCRIPT_DIR/build-gdrive.sh"
fi

echo "==> Building Vault plugin & TUI..."
zig build

chmod 755 "$VAULT_ROOT"/zig-out/lib/*.so 2>/dev/null || true

CMD="${1:-tui}"
if [[ "$CMD" == "tui" || "$CMD" == "-t" || "$CMD" == "--tui" || "$CMD" == "serve" || "$CMD" == "-s" || "$CMD" == "--serve" ]]; then
    shift || true
    DB_PATH="${VAULT_DB_PATH:-$VAULT_ROOT/data/vault_catalog.db}"
    cleanup_db() {
        rm -f "$DB_PATH" "${DB_PATH}-wal" "${DB_PATH}-shm"
    }
    trap cleanup_db EXIT INT TERM
    echo "==> Starting Parabellum Engine with TUI ('$PIPELINE')..."
    "$ENGINE_BIN" --plugin-dir "$PARABELLUM_PLUGIN_DIR" \
        --serve --transport tui --pipeline "$PIPELINE" "$@"
elif [[ "$CMD" == "validate" || "$CMD" == "-v" || "$CMD" == "--validate" ]]; then
    shift || true
    echo "==> Validating pipeline '$PIPELINE'..."
    exec "$ENGINE_BIN" --plugin-dir "$PARABELLUM_PLUGIN_DIR" validate "$PIPELINE" "$@"
elif [[ "$CMD" == "run" ]]; then
    shift || true
    echo "==> Running Parabellum pipeline '$PIPELINE'..."
    exec "$ENGINE_BIN" --plugin-dir "$PARABELLUM_PLUGIN_DIR" run "$PIPELINE" "$@"
else
    exec "$ENGINE_BIN" --plugin-dir "$PARABELLUM_PLUGIN_DIR" run "$@"
fi
