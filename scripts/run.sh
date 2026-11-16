#!/usr/bin/env bash
set -euo pipefail

ENGINE_BIN="${PARABELLUM_ENGINE_BIN:-../engine/zig-out/bin/parabellum}"
PIPELINE="${1:-./configs/pipeline.yaml}"

zig build
exec "$ENGINE_BIN" run "$PIPELINE"

