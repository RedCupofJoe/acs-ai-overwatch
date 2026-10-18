# syntax=docker/dockerfile:1
# ACS AI Overwatch console — talks to every test-range agent; not itself an ACS-tracked agent.
FROM registry.access.redhat.com/ubi9/python-312:latest

USER 0
ENV HOST=0.0.0.0
ENV PORT=8000
ENV OVERWATCH_UI_DIR=/opt/overwatch-console/ui
ENV HOME=/opt/app-root

RUN mkdir -p /opt/overwatch-console /opt/overwatch-console/ui \
  && chown -R 1001:0 /opt/overwatch-console /opt/app-root

COPY agents/overwatch-console/server.py /opt/overwatch-console/server.py
COPY agents/overwatch-console/ui /opt/overwatch-console/ui
RUN python3 -m pip install --upgrade pip \
  && python3 -m pip install --no-cache-dir "fastapi>=0.115.0" "uvicorn[standard]>=0.32.0" "httpx>=0.27.0" "pydantic>=2.0" \
  && chown -R 1001:0 /opt/overwatch-console

USER 1001
WORKDIR /opt/overwatch-console
CMD ["python3", "server.py"]
