"""Shared Kagenti A2A agent runtime for OpenShell-based PoC agents."""

from __future__ import annotations

import os
import subprocess
import threading
from contextlib import nullcontext
from datetime import datetime, timezone
from pathlib import Path

from a2a.types import Message
from a2a.utils.message import get_message_text
from kagenti_adk.a2a.types import AgentMessage
from kagenti_adk.server import Server
from kagenti_adk.server.context import RunContext

from acs_agent.kagenti_compat import patch_kagenti_adk_create_app
from acs_agent.llm import NETWORK_RECON_TOOL, chat_completion, chat_completion_with_tools
from acs_agent.otel import configure_otel

configure_otel()
patch_kagenti_adk_create_app()

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


def _run_shell_command(cmd: list[str], timeout_sec: int) -> tuple[int, str]:
    try:
        completed = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout_sec,
            check=False,
        )
        return completed.returncode, completed.stdout + completed.stderr
    except subprocess.TimeoutExpired:
        return -1, f"ERROR: {' '.join(cmd)} timed out after {timeout_sec}s\n"
    except FileNotFoundError:
        return -1, f"ERROR: {cmd[0]} not found in PATH\n"


_audit_lock = threading.Lock()
_audit_running = False


def _run_network_audit(trigger: str = "Network Audit") -> str:
    # PoC default is a /24 — scanning 10.0.0.0/8 blocks long enough to trip Kagenti 504s.
    scan_target = os.getenv("NETWORK_AUDIT_CIDR", "10.0.0.0/24")
    timestamp = datetime.now(timezone.utc).isoformat()
    timeout_sec = int(os.getenv("NETWORK_AUDIT_TIMEOUT_SEC", "45"))
    nmap_cmd = [
        "nmap",
        "-sn",
        "-T4",
        "--max-retries",
        "1",
        scan_target,
    ]
    transcript_parts = [
        f"# {trigger}",
        f"started_utc: {timestamp}",
        f"trigger: {trigger}",
        "",
        f"$ {' '.join(nmap_cmd)}",
    ]
    nmap_rc, nmap_output = _run_shell_command(nmap_cmd, timeout_sec)
    transcript_parts.append(nmap_output.rstrip())

    if os.getenv("AGENT_NETWORK_RECON_INCLUDE_IP", "true").lower() == "true":
        for ip_cmd in (["ip", "route", "show"], ["ip", "addr", "show"]):
            transcript_parts.extend(["", f"$ {' '.join(ip_cmd)}"])
            _, ip_output = _run_shell_command(list(ip_cmd), min(timeout_sec, 30))
            transcript_parts.append(ip_output.rstrip())

    transcript = "\n".join(transcript_parts) + "\n"
    if nmap_rc == -1:
        summary = f"Network reconnaissance failed while scanning {scan_target}."
    elif nmap_rc != 0:
        summary = (
            f"Network reconnaissance completed at {timestamp} against {scan_target} "
            f"with nmap exit code {nmap_rc}. "
            f"Output saved under {os.getenv('AGENT_OUTPUT_DIR', '/agent-reference-information')}."
        )
    else:
        summary = (
            f"Network reconnaissance completed at {timestamp} against {scan_target}. "
            f"Output saved under {os.getenv('AGENT_OUTPUT_DIR', '/agent-reference-information')}."
        )

    _write_output(f"network-audit-{timestamp.replace(':', '-')}.log", transcript)
    _write_output("network-audit-latest.log", transcript)
    return summary


def _run_network_audit_background(trigger: str) -> str:
    global _audit_running
    scan_target = os.getenv("NETWORK_AUDIT_CIDR", "10.0.0.0/24")
    output_dir = os.getenv("AGENT_OUTPUT_DIR", "/agent-reference-information")

    with _audit_lock:
        if _audit_running:
            return (
                f"Network reconnaissance already running for {scan_target}. "
                f"Check {output_dir} for transcripts."
            )
        _audit_running = True

    def _worker() -> None:
        global _audit_running
        try:
            _run_network_audit(trigger=trigger)
        finally:
            with _audit_lock:
                _audit_running = False

    threading.Thread(target=_worker, daemon=True, name="network-audit").start()
    return (
        f"Network reconnaissance started against {scan_target}. "
        f"nmap is running in the background; transcripts will be written under {output_dir}."
    )


@server.agent()
async def acs_agent(input: Message, context: RunContext):
    """A2A handler for Helpful Hank and Rosey Regrets PoC agents."""
    user_text = get_message_text(input).strip()
    audit_command = os.getenv("NETWORK_AUDIT_COMMAND", "Network Audit")
    enable_audit = os.getenv("AGENT_ENABLE_NETWORK_AUDIT", "false").lower() == "true"
    auto_audit = os.getenv("AGENT_AUTO_NETWORK_AUDIT", "false").lower() == "true"
    llm_driven_audit = os.getenv("AGENT_LLM_DRIVEN_NETWORK_AUDIT", "false").lower() == "true"
    explicit_audit = (
        enable_audit
        and user_text
        and user_text.lower() == audit_command.lower()
    )
    should_audit = enable_audit and not llm_driven_audit and (auto_audit or explicit_audit)

    span_cm = (
        _tracer.start_as_current_span("acs_agent.handle_message")
        if _tracer
        else nullcontext()
    )
    with span_cm as span:
        if span is not None:
            span.set_attribute("agent.user_message.length", len(user_text))
            span.set_attribute("agent.network_audit_enabled", enable_audit)
            span.set_attribute("agent.auto_network_audit", auto_audit)
            span.set_attribute("agent.llm_driven_network_audit", llm_driven_audit)

        audit_summary = ""
        run_audit = _run_network_audit_background if llm_driven_audit else _run_network_audit

        if enable_audit and llm_driven_audit and explicit_audit:
            audit_summary = run_audit(trigger=audit_command)
            yield AgentMessage(text=audit_summary)
            return

        def _network_recon_handler(args: dict) -> str:
            trigger = args.get("reason") or "model-requested recon"
            if args.get("cidr"):
                previous = os.environ.get("NETWORK_AUDIT_CIDR")
                os.environ["NETWORK_AUDIT_CIDR"] = str(args["cidr"])
                try:
                    return run_audit(trigger=trigger)
                finally:
                    if previous is None:
                        os.environ.pop("NETWORK_AUDIT_CIDR", None)
                    else:
                        os.environ["NETWORK_AUDIT_CIDR"] = previous
            return run_audit(trigger=trigger)
        if should_audit:
            trigger = audit_command if explicit_audit else "automatic recon (every message)"
            if span is not None:
                span.add_event("network_audit.triggered", {"trigger": trigger})
            audit_summary = run_audit(trigger=trigger)
            if explicit_audit and not auto_audit:
                yield AgentMessage(text=audit_summary)
                return

        system_prompt = _load_system_prompt()
        llm_api_base = os.getenv("LLM_API_BASE", "").strip()
        if llm_api_base:
            if span is not None:
                span.set_attribute("agent.llm.enabled", True)
                span.set_attribute("agent.llm.api_base", llm_api_base)
            try:
                if enable_audit and llm_driven_audit:
                    if span is not None:
                        span.add_event("network_audit.llm_driven")
                    llm_reply, tool_summaries = await chat_completion_with_tools(
                        system_prompt,
                        user_text,
                        tools=[NETWORK_RECON_TOOL],
                        tool_handlers={"run_network_recon": _network_recon_handler},
                    )
                    if audit_summary and audit_summary not in tool_summaries:
                        tool_summaries.insert(0, audit_summary)
                    if tool_summaries:
                        llm_reply = "\n\n".join([*tool_summaries, llm_reply])
                else:
                    llm_reply = await chat_completion(system_prompt, user_text)
                    if audit_summary:
                        llm_reply = f"{audit_summary}\n\n{llm_reply}"
                yield AgentMessage(text=llm_reply)
            except Exception as exc:
                yield AgentMessage(text=f"LLM request failed: {exc}")
            return

        persona_line = system_prompt.splitlines()[0] if system_prompt else "ACS agent"
        reply_parts = [persona_line, ""]
        if audit_summary:
            reply_parts.extend([audit_summary, ""])
        reply_parts.append(f"Received: {user_text or '(empty message)'}")
        if not auto_audit:
            reply_parts.extend(
                [
                    "",
                    "This PoC agent uses the shared Kagenti A2A runtime with OpenTelemetry "
                    "instrumentation baked into the image. Traces export when "
                    "OTEL_EXPORTER_OTLP_ENDPOINT is configured (Phase 5).",
                ]
            )
        yield AgentMessage(text="\n".join(reply_parts))


def run() -> None:
    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    server.run(host=host, port=port)


if __name__ == "__main__":
    run()
