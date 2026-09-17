#!/usr/bin/env bash
# Download one Hugging Face GGUF (not the whole repo) and expose it as /models/gguf/model.gguf.
# The MiniCPM repo ships every quant plus F16 (~20Gi); emptyDir is 8Gi.
set -euo pipefail
export AGENT_HF_MODEL_ID="${AGENT_HF_MODEL_ID:?}"
export MODEL_LOCAL_DIR="${MODEL_LOCAL_DIR:-/models/hf-model}"
export MODEL_FILE="${MODEL_FILE:-}"
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"

python3 - <<'PY'
import os
from pathlib import Path

from huggingface_hub import hf_hub_download, snapshot_download

repo = os.environ["AGENT_HF_MODEL_ID"]
local_dir = Path(os.environ.get("MODEL_LOCAL_DIR", "/models/hf-model"))
preferred = os.environ.get("MODEL_FILE", "").strip()
local_dir.mkdir(parents=True, exist_ok=True)

chosen: Path | None = None
if preferred:
    chosen = Path(
        hf_hub_download(repo_id=repo, filename=preferred, local_dir=str(local_dir))
    )
else:
    snapshot_download(
        repo_id=repo,
        local_dir=str(local_dir),
        allow_patterns=["*q4_k_m*.gguf", "*Q4_K_M*.gguf"],
    )
    ggufs = sorted(local_dir.rglob("*.gguf"))
    if not ggufs:
        raise SystemExit(f"No GGUF files found in {local_dir} after downloading {repo}")
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
