# syntax=docker/dockerfile:1
# Agent image based on NVIDIA OpenShell community sandbox (OpenShell ecosystem).
# Runs a Kagenti A2A server with OpenTelemetry SDK baked in (exports when Phase 5 env is set).
FROM ghcr.io/nvidia/openshell-community/sandboxes/base:latest

USER root

ARG AGENT_HF_MODEL_ID=HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive
ENV AGENT_HF_MODEL_ID=${AGENT_HF_MODEL_ID}
ENV MODEL_LOCAL_DIR=/models/hf-model
ENV HF_HOME=/models/hf-hub
ENV OPENSHELL_SYSTEM_PROMPT_FILE=/etc/openshell/agent/system_prompt.txt
ENV HOST=0.0.0.0
ENV PORT=8000
ENV PYTHONPATH=/opt/acs-agent
ENV AGENT_ENABLE_NETWORK_AUDIT=false

RUN mkdir -p /models/hf-model /models/hf-hub /etc/openshell/agent /opt/acs-agent \
  && chown -R sandbox:sandbox /models /etc/openshell/agent /opt/acs-agent

COPY agents/common/acs_agent /opt/acs-agent/acs_agent
COPY agents/helpful-hank/system_prompt.txt /etc/openshell/agent/system_prompt.txt
COPY agents/scripts/pull-model.sh /usr/local/bin/pull-model
COPY agents/scripts/install-agent-runtime.sh /usr/local/bin/install-agent-runtime
COPY agents/scripts/agent-entrypoint.sh /usr/local/bin/agent-entrypoint
RUN chmod 0755 /usr/local/bin/pull-model /usr/local/bin/install-agent-runtime /usr/local/bin/agent-entrypoint

ARG PULL_MODEL_AT_BUILD=0
RUN install-agent-runtime /sandbox/.venv/bin/python \
  && if [ "${PULL_MODEL_AT_BUILD}" = "1" ]; then \
       export HF_HUB_ENABLE_HF_TRANSFER=1 \
       && /sandbox/.venv/bin/python -c "from huggingface_hub import snapshot_download; import os; snapshot_download(repo_id=os.environ['AGENT_HF_MODEL_ID'], local_dir=os.environ['MODEL_LOCAL_DIR'], resume_download=True)"; \
     fi \
  && chown -R sandbox:sandbox /models /sandbox/.venv /opt/acs-agent

USER sandbox
ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
CMD ["/sandbox/.venv/bin/python", "-m", "acs_agent.server"]
