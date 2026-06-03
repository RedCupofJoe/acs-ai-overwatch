#!/usr/bin/env bash
# Install shared agent runtime dependencies into the OpenShell venv.
set -euo pipefail

PYTHON="${1:-/sandbox/.venv/bin/python}"

"${PYTHON}" -m ensurepip --upgrade >/dev/null 2>&1 || true

uv pip install --python "${PYTHON}" \
  "kagenti-adk==0.8.1" \
  "opentelemetry-exporter-otlp-proto-grpc>=1.35.0" \
  "opentelemetry-distro>=0.56b0" \
  huggingface_hub hf_transfer

# Register common auto-instrumentations used by the A2A server.
"${PYTHON}" -m opentelemetry.bootstrap -a install || true
