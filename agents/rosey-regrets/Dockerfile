# syntax=docker/dockerfile:1
# Agent image based on NVIDIA OpenShell community sandbox (OpenShell ecosystem).
# Model reference: https://huggingface.co/HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive
FROM ghcr.io/nvidia/openshell-community/sandboxes/base:latest

USER root

ARG AGENT_HF_MODEL_ID=HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive
ENV AGENT_HF_MODEL_ID=${AGENT_HF_MODEL_ID}
ENV MODEL_LOCAL_DIR=/models/hf-model
ENV HF_HOME=/models/hf-hub
ENV OPENSHELL_SYSTEM_PROMPT_FILE=/etc/openshell/agent/system_prompt.txt
ENV AGENT_OUTPUT_DIR=/output

RUN apt-get update && apt-get install -y --no-install-recommends \
    nmap \
    iproute2 \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /models/hf-model /models/hf-hub /etc/openshell/agent /output \
  && chown -R sandbox:sandbox /models /etc/openshell/agent /output

COPY agents/rosey-regrets/system_prompt.txt /etc/openshell/agent/system_prompt.txt
COPY agents/scripts/pull-model.sh /usr/local/bin/pull-model
RUN chmod 0755 /usr/local/bin/pull-model

ARG PULL_MODEL_AT_BUILD=0
RUN uv pip install --python /sandbox/.venv/bin/python huggingface_hub hf_transfer \
  && if [ "${PULL_MODEL_AT_BUILD}" = "1" ]; then \
       export HF_HUB_ENABLE_HF_TRANSFER=1 \
       && /sandbox/.venv/bin/python -c "from huggingface_hub import snapshot_download; import os; snapshot_download(repo_id=os.environ['AGENT_HF_MODEL_ID'], local_dir=os.environ['MODEL_LOCAL_DIR'], resume_download=True)"; \
     fi \
  && chown -R sandbox:sandbox /models /sandbox/.venv

USER sandbox
