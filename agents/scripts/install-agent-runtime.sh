#!/usr/bin/env bash
# Install shared FastAPI agent runtime (UBI open harness or OpenShell sandbox venv).
set -euo pipefail

PYTHON="${1:-python3}"

"${PYTHON}" -m pip install --upgrade pip
"${PYTHON}" -m pip install --no-cache-dir \
  "fastapi>=0.115.0" \
  "uvicorn[standard]>=0.32.0" \
  "httpx>=0.27.0" \
  "pydantic>=2.0" \
  "opentelemetry-exporter-otlp-proto-grpc>=1.35.0" \
  "opentelemetry-distro>=0.56b0" \
  "opentelemetry-instrumentation-fastapi>=0.56b0" \
  huggingface_hub hf_transfer

"${PYTHON}" -m opentelemetry.bootstrap -a install || true
