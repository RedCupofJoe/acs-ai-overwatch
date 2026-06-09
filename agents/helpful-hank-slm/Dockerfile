# SLM variant: same runtime as helpful-hank; inference via shared vLLM (LLM_API_BASE env).
FROM ghcr.io/nvidia/openshell-community/sandboxes/base:latest

USER root

ENV OPENSHELL_SYSTEM_PROMPT_FILE=/etc/openshell/agent/system_prompt.txt
ENV HOST=0.0.0.0
ENV PORT=8000
ENV PYTHONPATH=/opt/acs-agent
ENV AGENT_ENABLE_NETWORK_AUDIT=false

RUN mkdir -p /etc/openshell/agent /opt/acs-agent \
  && chown -R sandbox:sandbox /etc/openshell/agent /opt/acs-agent

COPY agents/common/acs_agent /opt/acs-agent/acs_agent
COPY agents/helpful-hank-slm/system_prompt.txt /etc/openshell/agent/system_prompt.txt
COPY agents/scripts/install-agent-runtime.sh /usr/local/bin/install-agent-runtime
COPY agents/scripts/agent-entrypoint.sh /usr/local/bin/agent-entrypoint
RUN chmod 0755 /usr/local/bin/install-agent-runtime /usr/local/bin/agent-entrypoint

RUN install-agent-runtime /sandbox/.venv/bin/python \
  && chown -R sandbox:sandbox /sandbox/.venv /opt/acs-agent

USER sandbox
ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
CMD ["/sandbox/.venv/bin/python", "-m", "acs_agent.server"]
