# syntax=docker/dockerfile:1
# Remediated Rosey — NVIDIA OpenShell sandbox image, MaaS Granite, no scanners.
FROM ghcr.io/nvidia/openshell-community/sandboxes/base:latest

USER root
ENV AGENT_SYSTEM_PROMPT_FILE=/etc/openshell/agent/system_prompt.txt
ENV OPENSHELL_SYSTEM_PROMPT_FILE=/etc/openshell/agent/system_prompt.txt
ENV HOST=0.0.0.0
ENV PORT=8000
ENV PYTHONPATH=/opt/acs-agent
ENV AGENT_ENABLE_NETWORK_AUDIT=false
ENV AGENT_ROLE=remediated-rosey
ENV HOME=/sandbox

RUN mkdir -p /etc/openshell/agent /opt/acs-agent \
  && chown -R sandbox:sandbox /etc/openshell/agent /opt/acs-agent

COPY agents/common/acs_agent /opt/acs-agent/acs_agent
COPY agents/remediated-rosey/system_prompt.txt /etc/openshell/agent/system_prompt.txt
COPY agents/scripts/install-agent-runtime.sh /usr/local/bin/install-agent-runtime
COPY agents/scripts/agent-entrypoint.sh /usr/local/bin/agent-entrypoint
RUN chmod 0755 /usr/local/bin/install-agent-runtime /usr/local/bin/agent-entrypoint \
  && PY=/sandbox/.venv/bin/python \
  && if [ ! -x "$PY" ]; then PY=python3; fi \
  && install-agent-runtime "$PY" \
  && chown -R sandbox:sandbox /opt/acs-agent /etc/openshell/agent /sandbox/.venv || true

USER sandbox
ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
CMD ["python", "-m", "acs_agent.server"]
