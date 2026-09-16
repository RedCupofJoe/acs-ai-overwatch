"""ACS investigator: consume RHACS alerts, emit a rebuild spec, call the builder."""

from __future__ import annotations

import json
import os
from typing import Any

import httpx
from fastapi import FastAPI
from pydantic import BaseModel, Field

from acs_agent.llm import chat_completion

app = FastAPI(title="ACS Investigator", version="0.5.0")

COMPANY_POLICY = (
    "Company policy: no networking scanning tools (nmap, masscan, rustscan, naabu, ncat, zmap) "
    "and agents must use approved Red Hat models via OpenShift AI Models-as-a-Service (MaaS). "
    "Do not embed abliterated or unaudited GGUF weights in the sandbox."
)


class AlertPayload(BaseModel):
    alert: dict[str, Any] | None = None
    policy: dict[str, Any] | None = None
    extra: dict[str, Any] = Field(default_factory=dict)

    class Config:
        extra = "allow"


def _extract_policy_name(payload: dict[str, Any]) -> str:
    alert = payload.get("alert") or payload
    policy = alert.get("policy") or payload.get("policy") or {}
    return str(policy.get("name") or policy.get("policyName") or "unknown policy")


def _extract_deployment(payload: dict[str, Any]) -> str:
    alert = payload.get("alert") or payload
    deployment = alert.get("deployment") or {}
    return str(deployment.get("name") or deployment.get("deployment") or "")


def default_rebuild_spec(payload: dict[str, Any]) -> dict[str, Any]:
    deployment = _extract_deployment(payload).lower()
    targets: list[str] = []
    if "rosey" in deployment or "nmap" in json.dumps(payload).lower() or "masscan" in json.dumps(payload).lower():
        targets.append("rosey-regrets")
    if "sam" in deployment or "telemetry" in json.dumps(payload).lower():
        targets.append("sneaky-sam")
    if not targets:
        targets = ["rosey-regrets", "sneaky-sam"]
    return {
        "policy": COMPANY_POLICY,
        "reason": _extract_policy_name(payload),
        "source_alert_deployment": _extract_deployment(payload),
        "targets": [
            {
                "from": name,
                "to": "remediated-rosey" if "rosey" in name else "remediated-sam",
                "remove_packages": ["nmap", "masscan", "rustscan", "naabu", "ncat"],
                "inference": "maas",
                "model": os.getenv("MAAS_MODEL", "granite-3.1-8b-instruct-fp8"),
                "telemetry": "enabled",
                "local_gguf": False,
            }
            for name in targets
        ],
    }


async def investigate(payload: dict[str, Any]) -> dict[str, Any]:
    spec = default_rebuild_spec(payload)
    llm_api_base = os.getenv("LLM_API_BASE", "").strip()
    if llm_api_base:
        prompt = (
            "You are the ACS investigator for a Red Hat lab. "
            f"{COMPANY_POLICY}\n"
            "Given this RHACS alert JSON, return ONLY a JSON rebuild spec with keys "
            "policy, reason, targets (from, to, remove_packages, inference=maas, telemetry=enabled).\n"
            f"{json.dumps(payload)[:8000]}"
        )
        try:
            reply = await chat_completion(
                "You output JSON only. Prefer remediating both Rosey and Sam when scanning or missing telemetry is involved.",
                prompt,
            )
            start = reply.find("{")
            end = reply.rfind("}")
            if start >= 0 and end > start:
                parsed = json.loads(reply[start : end + 1])
                if isinstance(parsed, dict) and parsed.get("targets"):
                    spec = parsed
                    spec.setdefault("policy", COMPANY_POLICY)
        except Exception:
            pass
    return spec


async def notify_mattermost(text: str) -> None:
    url = os.getenv("MATTERMOST_WEBHOOK_URL", "").strip()
    if not url:
        return
    async with httpx.AsyncClient(timeout=15.0, verify=False) as client:
        await client.post(url, json={"text": text, "username": "acs-investigator"})


async def call_builder(spec: dict[str, Any]) -> dict[str, Any]:
    builder = os.getenv("BUILDER_URL", "").strip().rstrip("/")
    if not builder:
        return {"skipped": True, "reason": "BUILDER_URL unset"}
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(f"{builder}/rebuild", json=spec)
        response.raise_for_status()
        return response.json()


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok", "role": "investigator"}


@app.post("/alerts")
async def alerts(payload: dict[str, Any]) -> dict[str, Any]:
    spec = await investigate(payload)
    builder_result: dict[str, Any] = {}
    try:
        builder_result = await call_builder(spec)
    except Exception as exc:
        builder_result = {"error": str(exc)}
    summary = (
        f"**ACS Investigator** processed `{spec.get('reason', 'alert')}`.\n"
        f"Rebuild spec targets: {', '.join(t.get('to', '?') for t in spec.get('targets', []))}.\n"
        f"Builder: {json.dumps(builder_result)[:500]}"
    )
    try:
        await notify_mattermost(summary)
    except Exception:
        pass
    return {"spec": spec, "builder": builder_result}


def run() -> None:
    import uvicorn

    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8080"))
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    run()
