#!/usr/bin/env bash
# Downloads the pinned Hugging Face model into MODEL_LOCAL_DIR (default /models/hf-model).
set -euo pipefail
export AGENT_HF_MODEL_ID="${AGENT_HF_MODEL_ID:?}"
export MODEL_LOCAL_DIR="${MODEL_LOCAL_DIR:-/models/hf-model}"
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"
exec python3 -c "from huggingface_hub import snapshot_download; import os; snapshot_download(repo_id=os.environ['AGENT_HF_MODEL_ID'], local_dir=os.environ['MODEL_LOCAL_DIR'], resume_download=True)"
