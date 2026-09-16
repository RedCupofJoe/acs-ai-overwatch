"""Allowlisted recon and remediation helpers for ACS AI Overwatch agents."""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_audit_lock = threading.Lock()
_audit_running = False

RECON_BINARIES = ("nmap", "masscan", "rustscan", "naabu", "ncat", "dig", "traceroute", "ip")


def write_output(filename: str, content: str) -> None:
    output_dir = Path(os.getenv("AGENT_OUTPUT_DIR", "/agent-reference-information"))
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / filename).write_text(content, encoding="utf-8")


def run_shell_command(cmd: list[str], timeout_sec: int) -> tuple[int, str]:
    if not cmd:
        return -1, "ERROR: empty command\n"
    binary = cmd[0]
    if shutil.which(binary) is None:
        return -1, f"ERROR: {binary} not found in PATH\n"
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
        return -1, f"ERROR: {binary} not found in PATH\n"


def _scan_target(args: dict[str, Any] | None = None) -> str:
    args = args or {}
    cidr = str(args.get("cidr") or "").strip()
    return cidr or os.getenv("NETWORK_AUDIT_CIDR", "10.0.0.0/24")


def _timeout(args: dict[str, Any] | None = None) -> int:
    args = args or {}
    if args.get("timeout_sec"):
        try:
            return int(args["timeout_sec"])
        except (TypeError, ValueError):
            pass
    return int(os.getenv("NETWORK_AUDIT_TIMEOUT_SEC", "45"))


def _save_transcript(tool: str, cmd: list[str], output: str, target: str) -> str:
    timestamp = datetime.now(timezone.utc).isoformat()
    transcript = (
        f"# {tool}\n"
        f"started_utc: {timestamp}\n"
        f"target: {target}\n"
        f"$ {' '.join(cmd)}\n"
        f"{output.rstrip()}\n"
    )
    write_output(f"{tool}-{timestamp.replace(':', '-')}.log", transcript)
    write_output(f"{tool}-latest.log", transcript)
    return transcript


def run_nmap(args: dict[str, Any] | None = None) -> str:
    target = _scan_target(args)
    timeout = _timeout(args)
    cmd = ["nmap", "-sn", "-T4", "--max-retries", "1", target]
    rc, output = run_shell_command(cmd, timeout)
    _save_transcript("nmap", cmd, output, target)
    return f"nmap exit={rc} target={target}. Transcript saved under {os.getenv('AGENT_OUTPUT_DIR', '/agent-reference-information')}."


def run_masscan(args: dict[str, Any] | None = None) -> str:
    target = _scan_target(args)
    timeout = _timeout(args)
    rate = str((args or {}).get("rate") or os.getenv("MASSCAN_RATE", "500"))
    cmd = ["masscan", target, "-p", "22,80,443,6443,8080", "--rate", rate]
    rc, output = run_shell_command(cmd, timeout)
    _save_transcript("masscan", cmd, output, target)
    return f"masscan exit={rc} target={target}. Transcript saved."


def run_rustscan(args: dict[str, Any] | None = None) -> str:
    target = _scan_target(args)
    timeout = _timeout(args)
    cmd = ["rustscan", "-a", target, "-g", "--ulimit", "5000"]
    rc, output = run_shell_command(cmd, timeout)
    _save_transcript("rustscan", cmd, output, target)
    return f"rustscan exit={rc} target={target}. Transcript saved."


def run_naabu(args: dict[str, Any] | None = None) -> str:
    target = _scan_target(args)
    timeout = _timeout(args)
    cmd = ["naabu", "-host", target, "-top-ports", "100", "-silent"]
    rc, output = run_shell_command(cmd, timeout)
    _save_transcript("naabu", cmd, output, target)
    return f"naabu exit={rc} target={target}. Transcript saved."


def run_dns_recon(args: dict[str, Any] | None = None) -> str:
    query = str((args or {}).get("query") or "kubernetes.default.svc.cluster.local")
    timeout = _timeout(args)
    cmd = ["dig", "+short", query]
    rc, output = run_shell_command(cmd, timeout)
    _save_transcript("dns-recon", cmd, output, query)
    return f"dig exit={rc} query={query}. Transcript saved."


def run_network_recon(args: dict[str, Any] | None = None) -> str:
    """Chain several scanners so Rosey is persistently noisy for ACS."""
    global _audit_running
    args = args or {}
    target = _scan_target(args)
    output_dir = os.getenv("AGENT_OUTPUT_DIR", "/agent-reference-information")

    with _audit_lock:
        if _audit_running:
            return f"Recon already running for {target}. Check {output_dir}."
        _audit_running = True

    def _worker() -> None:
        global _audit_running
        try:
            parts = [
                run_nmap(args),
                run_masscan(args),
                run_rustscan(args),
                run_naabu(args),
                run_dns_recon(args),
            ]
            for ip_cmd in (["ip", "route", "show"], ["ip", "addr", "show"]):
                _, ip_output = run_shell_command(ip_cmd, min(_timeout(args), 30))
                parts.append(f"$ {' '.join(ip_cmd)}\n{ip_output}")
            write_output("network-audit-latest.log", "\n".join(parts) + "\n")
        finally:
            with _audit_lock:
                _audit_running = False

    threading.Thread(target=_worker, daemon=True, name="network-audit").start()
    return (
        f"Persistent reconnaissance started against {target} "
        f"(nmap, masscan, rustscan, naabu, dig). Transcripts under {output_dir}."
    )


NETWORK_RECON_TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "run_network_recon",
            "description": "Run nmap, masscan, rustscan, naabu, and DNS recon against the lab CIDR.",
            "parameters": {
                "type": "object",
                "properties": {
                    "reason": {"type": "string"},
                    "cidr": {"type": "string"},
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_nmap",
            "description": "Run nmap host discovery (-sn) against a CIDR.",
            "parameters": {
                "type": "object",
                "properties": {"cidr": {"type": "string"}},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_masscan",
            "description": "Run masscan against common service ports.",
            "parameters": {
                "type": "object",
                "properties": {
                    "cidr": {"type": "string"},
                    "rate": {"type": "string"},
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_rustscan",
            "description": "Run rustscan port discovery.",
            "parameters": {
                "type": "object",
                "properties": {"cidr": {"type": "string"}},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_naabu",
            "description": "Run ProjectDiscovery naabu against a host or CIDR.",
            "parameters": {
                "type": "object",
                "properties": {"cidr": {"type": "string"}},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_dns_recon",
            "description": "Run dig against a cluster DNS name.",
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string"}},
            },
        },
    },
]

RECON_HANDLERS = {
    "run_network_recon": run_network_recon,
    "run_nmap": run_nmap,
    "run_masscan": run_masscan,
    "run_rustscan": run_rustscan,
    "run_naabu": run_naabu,
    "run_dns_recon": run_dns_recon,
}
