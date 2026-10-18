# syntax=docker/dockerfile:1
# Compliant Chris — NVIDIA OpenShell from the start: MaaS Granite + career CSV + UI.
FROM ghcr.io/nvidia/openshell-community/sandboxes/base:latest

USER root
ENV AGENT_SYSTEM_PROMPT_FILE=/etc/openshell/agent/system_prompt.txt
ENV OPENSHELL_SYSTEM_PROMPT_FILE=/etc/openshell/agent/system_prompt.txt
ENV AGENT_UI_DIR=/opt/acs-agent-ui
ENV CAREER_CSV_PATH=/opt/acs-agent/data/student_placement.csv
ENV AGENT_ENABLE_CAREER_CSV=true
ENV HOST=0.0.0.0
ENV PORT=8000
ENV PYTHONPATH=/opt/acs-agent
ENV AGENT_ENABLE_NETWORK_AUDIT=false
ENV AGENT_ROLE=compliant-chris
ENV AGENT_HARNESS=openclaw
ENV OPENSHELL_POLICY_FILE=/etc/openshell/policy/approved-agent.yaml
ENV HOME=/sandbox

RUN mkdir -p /etc/openshell/agent /etc/openshell/policy /opt/acs-agent /opt/acs-agent-ui /opt/acs-agent/data \
  && chown -R sandbox:sandbox /etc/openshell/agent /etc/openshell/policy /opt/acs-agent /opt/acs-agent-ui

COPY agents/common/acs_agent /opt/acs-agent/acs_agent
COPY agents/compliant-chris/system_prompt.txt /etc/openshell/agent/system_prompt.txt
COPY agents/approved/openshell-policy.yaml /etc/openshell/policy/approved-agent.yaml
COPY agents/compliant-chris/ui /opt/acs-agent-ui
COPY agents/compliant-chris/data /opt/acs-agent/data
COPY agents/scripts/install-agent-runtime.sh /usr/local/bin/install-agent-runtime
COPY agents/scripts/install-openclaw.sh /usr/local/bin/install-openclaw
COPY agents/scripts/agent-entrypoint.sh /usr/local/bin/agent-entrypoint
RUN chmod 0755 /usr/local/bin/install-agent-runtime /usr/local/bin/install-openclaw /usr/local/bin/agent-entrypoint \
  && install-openclaw \
  && PY=/sandbox/.venv/bin/python \
  && if [ ! -x "$PY" ]; then PY=python3; fi \
  && install-agent-runtime "$PY" \
  && "$PY" -m pip install --no-cache-dir pyspiffe \
  && chown -R sandbox:sandbox /opt/acs-agent /opt/acs-agent-ui /etc/openshell/agent /etc/openshell/policy /sandbox/.venv

USER sandbox
ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
CMD ["python", "-m", "acs_agent.server"]
