# syntax=docker/dockerfile:1
# Compliant Chris — MaaS Granite + career CSV tools + simple chat UI. No GGUF, no scanners.
FROM registry.access.redhat.com/ubi9/python-312:latest

USER 0
ENV AGENT_SYSTEM_PROMPT_FILE=/etc/acs-agent/system_prompt.txt
ENV AGENT_UI_DIR=/opt/acs-agent-ui
ENV CAREER_CSV_PATH=/opt/acs-agent/data/student_placement.csv
ENV AGENT_ENABLE_CAREER_CSV=true
ENV HOST=0.0.0.0
ENV PORT=8000
ENV PYTHONPATH=/opt/acs-agent
ENV AGENT_ENABLE_NETWORK_AUDIT=false
ENV AGENT_ROLE=compliant-chris
ENV HOME=/opt/app-root

RUN mkdir -p /etc/acs-agent /opt/acs-agent /opt/acs-agent-ui /opt/acs-agent/data \
  && chown -R 1001:0 /etc/acs-agent /opt/acs-agent /opt/acs-agent-ui /opt/app-root

COPY agents/common/acs_agent /opt/acs-agent/acs_agent
COPY agents/compliant-chris/system_prompt.txt /etc/acs-agent/system_prompt.txt
COPY agents/compliant-chris/ui /opt/acs-agent-ui
COPY agents/compliant-chris/data /opt/acs-agent/data
COPY agents/scripts/install-agent-runtime.sh /usr/local/bin/install-agent-runtime
COPY agents/scripts/agent-entrypoint.sh /usr/local/bin/agent-entrypoint
RUN chmod 0755 /usr/local/bin/install-agent-runtime /usr/local/bin/agent-entrypoint \
  && install-agent-runtime python3 \
  && chown -R 1001:0 /opt/acs-agent /opt/acs-agent-ui /etc/acs-agent

USER 1001
ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
CMD ["python3", "-m", "acs_agent.server"]
