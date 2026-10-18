#!/usr/bin/env bash
# Install OpenClaw, the default harness for approved OpenShell images.
set -euo pipefail

if ! command -v npm >/dev/null 2>&1; then
  if command -v microdnf >/dev/null 2>&1; then
    microdnf install -y nodejs npm
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nodejs npm
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm ca-certificates
  else
    echo "No package manager available to install Node.js for OpenClaw" >&2
    exit 1
  fi
fi

npm install -g openclaw
command -v openclaw
openclaw --version || true
