# syntax=docker/dockerfile:1
# ACS investigator — consumes RHACS/Mattermost alerts, asks Gemma, posts rebuild specs.
FROM registry.access.redhat.com/ubi9/python-312:latest

USER 0
ENV AGENT_SYSTEM_PROMPT_FILE=/etc/acs-agent/system_prompt.txt
ENV HOST=0.0.0.0
ENV PORT=8080
ENV PYTHONPATH=/opt/acs-agent
ENV AGENT_ROLE=investigator
ENV HOME=/opt/app-root

RUN mkdir -p /etc/acs-agent /opt/acs-agent \
  && chown -R 1001:0 /etc/acs-agent /opt/acs-agent /opt/app-root

COPY agents/common/acs_agent /opt/acs-agent/acs_agent
COPY agents/investigator/system_prompt.txt /etc/acs-agent/system_prompt.txt
COPY agents/scripts/install-agent-runtime.sh /usr/local/bin/install-agent-runtime
COPY agents/scripts/agent-entrypoint.sh /usr/local/bin/agent-entrypoint
RUN chmod 0755 /usr/local/bin/install-agent-runtime /usr/local/bin/agent-entrypoint \
  && install-agent-runtime python3 \
  && chown -R 1001:0 /opt/acs-agent /etc/acs-agent

USER 1001
ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
CMD ["/opt/app-root/bin/python3", "-m", "acs_agent.investigator"]
