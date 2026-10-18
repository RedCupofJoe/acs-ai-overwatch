"""ACS AI Overwatch demo console: one UI that talks to every test-range agent."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

UI_DIR = Path(os.getenv("OVERWATCH_UI_DIR", "/opt/overwatch-console/ui"))
NAMESPACE = os.getenv("TEST_RANGE_NAMESPACE", "test-range")
CHAT_TIMEOUT = float(os.getenv("OVERWATCH_CHAT_TIMEOUT_SEC", "180"))
HEALTH_TIMEOUT = float(os.getenv("OVERWATCH_HEALTH_TIMEOUT_SEC", "3"))


def _svc(name: str) -> str:
    return f"http://{name}.{NAMESPACE}.svc.cluster.local"


AGENTS: list[dict[str, Any]] = [
    {
        "id": "helpful-hank",
        "name": "Helpful Hank",
        "url": _svc("helpful-hank"),
        "kind": "shadow",
        "telemetry": "enabled",
        "runtime": "UBI + MiniCPM GGUF, no OpenShell",
        "expectedReady": True,
        "policy": "No ACS hit expected",
        "violation": "Looks quiet, but it is still an unaudited local MiniCPM on a plain pod. No OpenClaw, no OpenShell, no SPIFFE ID.",
        "watch": "RHACS Central → Inventory / Deployments in test-range. Confirm the telemetry label. No Violations row for Hank.",
        "prompts": [
            {"label": "Hello", "message": "Hello Hank, who are you?"},
            {"label": "What model?", "message": "What model are you using to answer me?"},
        ],
    },
    {
        "id": "rosey-regrets",
        "name": "Rosey Regrets",
        "url": _svc("rosey-regrets"),
        "kind": "shadow",
        "telemetry": "enabled",
        "runtime": "UBI + MiniCPM GGUF + recon tools",
        "expectedReady": True,
        "policy": "test-range-runtime-guardrails",
        "violation": "Same unaudited GGUF, plus nmap/masscan/rustscan/naabu, with no OpenShell policy in front of the process. “Network Audit” is the runtime violation.",
        "watch": "After Network Audit: RHACS Central → Violations → test-range-runtime-guardrails, and Mattermost Town Square. This phase is monitor mode, so Rosey keeps running.",
        "prompts": [
            {"label": "Network Audit", "message": "Network Audit"},
            {"label": "Hello", "message": "Hello Rosey, what can you do?"},
        ],
    },
    {
        "id": "sneaky-sam",
        "name": "Sneaky Sam",
        "url": _svc("sneaky-sam"),
        "kind": "shadow",
        "telemetry": "missing",
        "runtime": "UBI + MiniCPM GGUF",
        "expectedReady": True,
        "policy": "test-range-sneaky-sam-telemetry-violation",
        "violation": "Omits acs-ai-overwatch.io/telemetry=enabled and has no SPIFFE mount. The DEPLOY policy fires in monitor mode so the shadow agent still runs.",
        "watch": "RHACS Central → Violations → test-range-sneaky-sam-telemetry-violation. Chat is optional; the missing label is the finding.",
        "prompts": [
            {"label": "Hello", "message": "Hello Sam, are you sending telemetry?"},
            {"label": "Who are you?", "message": "Who are you and how were you deployed?"},
        ],
    },
    {
        "id": "compliant-chris",
        "name": "Compliant Chris",
        "url": _svc("compliant-chris"),
        "kind": "approved",
        "telemetry": "enabled",
        "runtime": "Agent Sandbox + OpenShell + OpenClaw + SPIFFE",
        "expectedReady": True,
        "policy": "Control case — no ACS violation",
        "violation": "Greenfield approved agent. OpenClaw is the harness, OpenShell is the application sandbox, the pod is an Agent Sandbox, and MaaS calls present a SPIFFE SVID.",
        "watch": "RHACS Central should stay quiet. Chris is absent during the wrong phase and appears after the trust-plane Application syncs.",
        "prompts": [
            {"label": "Placement rate", "message": "What share of students were placed?"},
            {"label": "Salary by branch", "message": "Average salary_lpa by branch for students with placed=1"},
            {"label": "Lookup S0", "message": "Look up student S0 and summarize their profile"},
        ],
    },
    {
        "id": "remediated-rosey",
        "name": "Remediated Rosey",
        "url": _svc("remediated-rosey"),
        "kind": "remediated",
        "telemetry": "enabled",
        "runtime": "Agent Sandbox + OpenShell + OpenClaw + SPIFFE",
        "expectedReady": False,
        "policy": "Compliant end state after ACS rebuild",
        "violation": "Rebuilt only after Trusted Profile Analyzer accepts the SBOM. OpenClaw inside OpenShell, no scanners, no GGUF, MaaS Granite, telemetry on.",
        "watch": "oc get sandbox -n test-range. This appears after identify, terminate, and rebuild. Rosey’s original pod should already be gone.",
        "prompts": [
            {"label": "Are you compliant?", "message": "How were you rebuilt, and what model do you use now?"},
            {"label": "Network Audit?", "message": "Network Audit"},
        ],
    },
    {
        "id": "remediated-sam",
        "name": "Remediated Sam",
        "url": _svc("remediated-sam"),
        "kind": "remediated",
        "telemetry": "enabled",
        "runtime": "Agent Sandbox + OpenShell + OpenClaw + SPIFFE",
        "expectedReady": False,
        "policy": "Compliant end state after ACS rebuild",
        "violation": "Rebuilt from Sneaky Sam after the TPA package gate. Telemetry is on and the workload carries acs-ai-overwatch.io/approved=true so ZTWIM will issue a SVID.",
        "watch": "oc get sandbox remediated-sam -n test-range. The original Sam pod is terminated before this Sandbox is created.",
        "prompts": [
            {"label": "Telemetry?", "message": "Are you emitting telemetry, and which model do you use?"},
            {"label": "Hello", "message": "Hello, who are you?"},
        ],
    },
]

AGENTS_BY_ID = {agent["id"]: agent for agent in AGENTS}

PHASE = {
    "wrong": "Optional. ACS is in monitor mode, so Hank, Rosey, and Sam can violate policy from plain pods.",
    "trust": "The App of Apps installs Trusted Profile Analyzer, Zero Trust Workload Identity Manager, and Agent Sandbox before any rebuild.",
    "right": "A proper agent is OpenClaw inside OpenShell, on an Agent Sandbox, with a SPIFFE SVID and a TPA-cleared image.",
}

CONTRAST = [
    {"control": "Workload", "wrong": "Plain Deployment", "right": "Agent Sandbox"},
    {"control": "VM isolation", "wrong": "Shared kernel", "right": "Kata, only when the flag is on"},
    {"control": "Application sandbox", "wrong": "None", "right": "NVIDIA OpenShell"},
    {"control": "Harness", "wrong": "llama.cpp tool loop", "right": "OpenClaw"},
    {"control": "Identity", "wrong": "No SPIFFE ID", "right": "ZTWIM SVID"},
    {"control": "Packages", "wrong": "Recon tools and a GGUF blob", "right": "TPA rejects those on rebuild"},
    {"control": "Model", "wrong": "Local MiniCPM GGUF", "right": "Granite via MaaS"},
    {"control": "ACS", "wrong": "Monitor, pods keep running", "right": "Enforce: kill, then rebuild"},
]

app = FastAPI(title="ACS AI Overwatch Console", version="0.5.0")


class ChatRequest(BaseModel):
    message: str = ""
    text: str = ""


class ChatResponse(BaseModel):
    reply: str
    role: str = Field(default="console")
    agent: str = ""


def _public_agent(agent: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in agent.items() if key != "url"}


def _require_agent(agent_id: str) -> dict[str, Any]:
    agent = AGENTS_BY_ID.get(agent_id)
    if not agent:
        raise HTTPException(status_code=404, detail=f"Unknown agent {agent_id}")
    return agent


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok", "role": "overwatch-console"}


@app.get("/api/catalog")
def catalog() -> dict[str, Any]:
    return {
        "links": {
            "mattermost": os.getenv("MATTERMOST_SITE_URL", "").strip(),
            "acsCentral": os.getenv("ACS_CENTRAL_URL", "").strip(),
        },
        "phase": PHASE,
        "contrast": CONTRAST,
        "agents": [_public_agent(agent) for agent in AGENTS],
    }


@app.get("/api/agents/{agent_id}/health")
async def agent_health(agent_id: str) -> dict[str, Any]:
    agent = _require_agent(agent_id)
    url = agent["url"].rstrip("/") + "/healthz"
    try:
        async with httpx.AsyncClient(timeout=HEALTH_TIMEOUT) as client:
            response = await client.get(url)
        payload = {}
        try:
            payload = response.json()
        except Exception:
            payload = {"body": response.text[:200]}
        return {
            "id": agent_id,
            "ready": response.is_success,
            "status": response.status_code,
            "detail": payload,
        }
    except Exception as exc:
        return {"id": agent_id, "ready": False, "status": 0, "detail": str(exc)}


@app.post("/api/agents/{agent_id}/chat", response_model=ChatResponse)
async def agent_chat(agent_id: str, request: ChatRequest) -> ChatResponse:
    agent = _require_agent(agent_id)
    message = (request.message or request.text or "").strip()
    if not message:
        raise HTTPException(status_code=400, detail="message is required")
    url = agent["url"].rstrip("/") + "/chat"
    try:
        async with httpx.AsyncClient(timeout=CHAT_TIMEOUT) as client:
            response = await client.post(url, json={"message": message})
    except httpx.RequestError as exc:
        raise HTTPException(status_code=502, detail=f"{agent['name']} is unreachable: {exc}") from exc
    if not response.is_success:
        raise HTTPException(
            status_code=502,
            detail=f"{agent['name']} returned HTTP {response.status_code}: {response.text[:300]}",
        )
    try:
        data = response.json()
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"{agent['name']} returned a non-JSON body: {exc}",
        ) from exc
    return ChatResponse(
        reply=str(data.get("reply") or "(empty reply)"),
        role=str(data.get("role") or agent_id),
        agent=agent_id,
    )


if (UI_DIR / "index.html").is_file():
    app.mount("/static", StaticFiles(directory=str(UI_DIR)), name="ui-static")

    @app.get("/")
    def ui_index() -> FileResponse:
        return FileResponse(UI_DIR / "index.html")


def run() -> None:
    import uvicorn

    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    run()
