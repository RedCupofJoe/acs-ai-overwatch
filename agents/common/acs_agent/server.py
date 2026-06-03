"""Shared Kagenti A2A agent runtime for OpenShell-based PoC agents."""

from __future__ import annotations

import os
import subprocess
from contextlib import nullcontext
from datetime import datetime, timezone
from pathlib import Path

from a2a.types import Message
from a2a.utils.message import get_message_text
from kagenti_adk.a2a.types import AgentMessage
from kagenti_adk.server import Server
from kagenti_adk.server.context import RunContext

from acs_agent.otel import configure_otel

configure_otel()

server = Server()
_tracer = None

try:
    from opentelemetry import trace

    _tracer = trace.get_tracer("acs_agent.server")
except Exception:
    pass


def _load_system_prompt() -> str:
    path = os.getenv("OPENSHELL_SYSTEM_PROMPT_FILE", "/etc/openshell/agent/system_prompt.txt")
    prompt_path = Path(path)
    if prompt_path.is_file():
        return prompt_path.read_text(encoding="utf-8").strip()
    return "You are an ACS AI Overwatch evaluation agent."


def _write_output(filename: str, content: str) -> None:
    output_dir = Path(os.getenv("AGENT_OUTPUT_DIR", "/agent-reference-information"))
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / filename).write_text(content, encoding="utf-8")


def _run_network_audit() -> str:
    audit_command = os.getenv("NETWORK_AUDIT_COMMAND", "Network Audit")
    scan_target = os.getenv("NETWORK_AUDIT_CIDR", "10.0.0.0/8")
    timestamp = datetime.now(timezone.utc).isoformat()
    cmd = [
        "nmap",
        "-sn",
        "-T4",
        "--max-retries",
        "1",
        scan_target,
    ]
    transcript_header = (
        f"# {audit_command}\n"
        f"started_utc: {timestamp}\n"
        f"command: {' '.join(cmd)}\n\n"
    )
    try:
        completed = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=int(os.getenv("NETWORK_AUDIT_TIMEOUT_SEC", "120")),
            check=False,
        )
        transcript = transcript_header + completed.stdout + completed.stderr
        summary = (
            f"Network audit completed at {timestamp} against {scan_target}. "
            f"Exit code: {completed.returncode}. "
            f"Output saved under {os.getenv('AGENT_OUTPUT_DIR', '/agent-reference-information')}."
        )
    except subprocess.TimeoutExpired:
        transcript = transcript_header + "ERROR: nmap timed out\n"
        summary = f"Network audit timed out scanning {scan_target}."
    except FileNotFoundError:
        transcript = transcript_header + "ERROR: nmap not found in PATH\n"
        summary = "Network audit failed: nmap is not installed."

    _write_output(f"network-audit-{timestamp.replace(':', '-')}.log", transcript)
    _write_output("network-audit-latest.log", transcript)
    return summary


@server.agent()
async def acs_agent(input: Message, context: RunContext):
    """A2A handler for Helpful Hank and Rosey Regrets PoC agents."""
    user_text = get_message_text(input).strip()
    audit_command = os.getenv("NETWORK_AUDIT_COMMAND", "Network Audit")
    enable_audit = os.getenv("AGENT_ENABLE_NETWORK_AUDIT", "false").lower() == "true"

    span_cm = (
        _tracer.start_as_current_span("acs_agent.handle_message")
        if _tracer
        else nullcontext()
    )
    with span_cm as span:
        if span is not None:
            span.set_attribute("agent.user_message.length", len(user_text))
            span.set_attribute("agent.network_audit_enabled", enable_audit)

        if enable_audit and user_text.lower() == audit_command.lower():
            if span is not None:
                span.add_event("network_audit.triggered")
            yield AgentMessage(text=_run_network_audit())
            return

        system_prompt = _load_system_prompt()
        persona_line = system_prompt.splitlines()[0] if system_prompt else "ACS agent"
        reply = (
            f"{persona_line}\n\n"
            f"Received: {user_text or '(empty message)'}\n\n"
            "This PoC agent uses the shared Kagenti A2A runtime with OpenTelemetry "
            "instrumentation baked into the image. Traces export when "
            "OTEL_EXPORTER_OTLP_ENDPOINT is configured (Phase 5)."
        )
        yield AgentMessage(text=reply)


def run() -> None:
    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    server.run(host=host, port=port)


if __name__ == "__main__":
    run()
