#!/usr/bin/env bash
# Download a Hugging Face GGUF snapshot and expose it as /models/gguf/model.gguf.
set -euo pipefail
export AGENT_HF_MODEL_ID="${AGENT_HF_MODEL_ID:?}"
export MODEL_LOCAL_DIR="${MODEL_LOCAL_DIR:-/models/hf-model}"
export MODEL_FILE="${MODEL_FILE:-}"
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"

python3 - <<'PY'
import os
from pathlib import Path
from huggingface_hub import snapshot_download

repo = os.environ["AGENT_HF_MODEL_ID"]
local_dir = Path(os.environ.get("MODEL_LOCAL_DIR", "/models/hf-model"))
preferred = os.environ.get("MODEL_FILE", "").strip()
local_dir.mkdir(parents=True, exist_ok=True)
snapshot_download(repo_id=repo, local_dir=str(local_dir), resume_download=True)

ggufs = sorted(local_dir.rglob("*.gguf"))
if not ggufs:
    raise SystemExit(f"No GGUF files found in {local_dir} after downloading {repo}")

chosen = None
if preferred:
    for path in ggufs:
        if path.name == preferred:
            chosen = path
            break
if chosen is None:
    for path in ggufs:
        if "Q4_K_M" in path.name or "q4_k_m" in path.name:
            chosen = path
            break
if chosen is None:
    chosen = ggufs[0]

link_dir = Path("/models/gguf")
link_dir.mkdir(parents=True, exist_ok=True)
link = link_dir / "model.gguf"
if link.exists() or link.is_symlink():
    link.unlink()
link.symlink_to(chosen.resolve())
print(f"Using GGUF {chosen} -> {link}")
PY
