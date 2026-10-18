"""Agentic container builder: rebuild a violating agent only after TPA accepts its SBOM."""

from __future__ import annotations

import asyncio
import json
import os
import time
import uuid
from typing import Any

import httpx
from fastapi import FastAPI

app = FastAPI(title="ACS Agentic Builder", version="0.6.0")

DISALLOWED_PACKAGES = {"nmap", "masscan", "rustscan", "naabu", "ncat", "zmap"}
_STATUS: dict[str, dict[str, Any]] = {}
_TASKS: set[asyncio.Task[None]] = set()


def _runtime_image(dest: str) -> str:
    registry = os.getenv(
        "IMAGE_REGISTRY", "image-registry.openshift-image-registry.svc:5000"
    )
    org = os.getenv("IMAGE_ORG") or os.getenv("BUILDER_NAMESPACE", "acs-agent-builder")
    tag = os.getenv("IMAGE_TAG", "latest")
    return f"{registry}/{org}/{dest}:{tag}"


def _build_request(dest: str) -> dict[str, Any]:
    return {
        "apiVersion": "build.openshift.io/v1",
        "kind": "BuildRequest",
        "metadata": {"name": dest},
    }


def _k8s_session() -> tuple[str, dict[str, str], str] | None:
    host = os.getenv("KUBERNETES_SERVICE_HOST")
    port = os.getenv("KUBERNETES_SERVICE_PORT", "443")
    if not host:
        return None
    token = open("/var/run/secrets/kubernetes.io/serviceaccount/token", encoding="utf-8").read()
    ca_path = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    return f"https://{host}:{port}", headers, ca_path


async def k8s_apply(method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
    session = _k8s_session()
    if not session:
        return {"dryRun": True, "method": method, "path": path, "body": body}
    base, headers, ca_path = session
    async with httpx.AsyncClient(verify=ca_path, timeout=30.0) as client:
        if method == "PATCH":
            response = await client.patch(
                f"{base}{path}",
                headers={**headers, "Content-Type": "application/merge-patch+json"},
                content=json.dumps(body),
            )
            if response.status_code == 404:
                create_path = path.rsplit("/", 1)[0]
                response = await client.post(
                    f"{base}{create_path}",
                    headers=headers,
                    content=json.dumps(body),
                )
        else:
            response = await client.request(
                method,
                f"{base}{path}",
                headers=headers,
                content=json.dumps(body) if body is not None else None,
            )
            if method == "POST" and response.status_code == 409 and body:
                name = body.get("metadata", {}).get("name")
                patch_path = f"{path}/{name}" if name and not path.endswith(f"/{name}") else path
                response = await client.patch(
                    f"{base}{patch_path}",
                    headers={**headers, "Content-Type": "application/merge-patch+json"},
                    content=json.dumps(body),
                )
        response.raise_for_status()
        if not response.content:
            return {"status": response.status_code}
        try:
            parsed = response.json()
        except json.JSONDecodeError:
            return {"raw": response.text}
        return parsed if isinstance(parsed, dict) else {"raw": response.text}


async def start_buildconfig(dest: str) -> dict[str, Any]:
    namespace = os.getenv("BUILDER_NAMESPACE", "acs-agent-builder")
    return await k8s_apply(
        "POST",
        f"/apis/build.openshift.io/v1/namespaces/{namespace}/buildconfigs/{dest}/instantiate",
        _build_request(dest),
    )


def _approved_labels(dest: str) -> dict[str, str]:
    return {
        "app.kubernetes.io/name": dest,
        "app.kubernetes.io/component": "agent",
        "app.kubernetes.io/part-of": "acs-ai-overwatch",
        "acs-ai-overwatch.io/remediated": "true",
        "acs-ai-overwatch.io/approved": "true",
        "acs-ai-overwatch.io/telemetry": "enabled",
        "acs-ai-overwatch.io/runtime": "openshell",
        "acs-ai-overwatch.io/harness": "openclaw",
    }


def _sandbox_manifests(dest: str) -> list[tuple[str, str, dict[str, Any]]]:
    namespace = os.getenv("TEST_RANGE_NAMESPACE", "test-range")
    port = int(os.getenv("AGENTS_SERVICE_PORT", "8000"))
    sa = os.getenv("AGENT_SA", "openshell")
    image = _runtime_image(dest)
    labels = _approved_labels(dest)
    runtime = os.getenv("SANDBOX_RUNTIME_CLASS", "").strip()
    pod_spec: dict[str, Any] = {
        "serviceAccountName": sa,
        "containers": [
            {
                "name": dest,
                "image": image,
                "imagePullPolicy": "Always",
                "env": [
                    {"name": "HOST", "value": "0.0.0.0"},
                    {"name": "PORT", "value": str(port)},
                    {"name": "AGENT_ROLE", "value": dest},
                    {"name": "AGENT_HARNESS", "value": "openclaw"},
                    {"name": "AGENT_ENABLE_NETWORK_AUDIT", "value": "false"},
                    {
                        "name": "AGENT_SYSTEM_PROMPT_FILE",
                        "value": "/etc/openshell/agent/system_prompt.txt",
                    },
                    {
                        "name": "OPENSHELL_SYSTEM_PROMPT_FILE",
                        "value": "/etc/openshell/agent/system_prompt.txt",
                    },
                    {
                        "name": "OPENSHELL_POLICY_FILE",
                        "value": "/etc/openshell/policy/approved-agent.yaml",
                    },
                    {"name": "LLM_API_BASE", "value": os.getenv("MAAS_API_BASE", "")},
                    {
                        "name": "LLM_MODEL",
                        "value": os.getenv("MAAS_MODEL", "granite-3.1-8b-instruct-fp8"),
                    },
                    {"name": "LLM_USE_SPIFFE", "value": "true"},
                    {
                        "name": "SPIFFE_ENDPOINT_SOCKET",
                        "value": "unix:///spiffe-workload-api/spire-agent.sock",
                    },
                    {"name": "SPIFFE_AUDIENCE", "value": "maas"},
                    {
                        "name": "LLM_API_KEY",
                        "valueFrom": {
                            "secretKeyRef": {
                                "name": os.getenv("MAAS_API_KEY_SECRET", "maas-poc-api-key"),
                                "key": "api-key",
                            }
                        },
                    },
                ],
                "ports": [{"name": "http", "containerPort": port}],
                "readinessProbe": {"httpGet": {"path": "/healthz", "port": "http"}},
                "volumeMounts": [
                    {
                        "name": "spiffe-workload-api",
                        "mountPath": "/spiffe-workload-api",
                        "readOnly": True,
                    }
                ],
            }
        ],
        "volumes": [
            {
                "name": "spiffe-workload-api",
                "csi": {"driver": "csi.spiffe.io", "readOnly": True},
            }
        ],
    }
    if runtime:
        pod_spec["runtimeClassName"] = runtime
    sandbox = {
        "apiVersion": "agents.x-k8s.io/v1beta1",
        "kind": "Sandbox",
        "metadata": {"name": dest, "namespace": namespace, "labels": labels},
        "spec": {
            "podTemplate": {
                "metadata": {"labels": labels},
                "spec": pod_spec,
            }
        },
    }
    service = {
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {"name": dest, "namespace": namespace, "labels": labels},
        "spec": {
            "selector": {"app.kubernetes.io/name": dest},
            "ports": [{"name": "http", "port": 80, "targetPort": port}],
        },
    }
    return [
        (
            "PATCH",
            f"/apis/agents.x-k8s.io/v1beta1/namespaces/{namespace}/sandboxes/{dest}",
            sandbox,
        ),
        ("PATCH", f"/api/v1/namespaces/{namespace}/services/{dest}", service),
    ]


def _disallowed_components(sbom: dict[str, Any]) -> list[str]:
    found: list[str] = []
    for component in sbom.get("components") or []:
        if not isinstance(component, dict):
            continue
        name = str(component.get("name") or "").lower()
        purl = str(component.get("purl") or "").lower()
        if name in DISALLOWED_PACKAGES or name.endswith(".gguf") or ".gguf" in purl or "/gguf" in purl:
            found.append(name or purl)
    return found


def _sbom_job(dest: str, image: str) -> dict[str, Any]:
    namespace = os.getenv("BUILDER_NAMESPACE", "acs-agent-builder")
    registry = os.getenv("IMAGE_REGISTRY", "image-registry.openshift-image-registry.svc:5000")
    name = f"sbom-{dest}-{uuid.uuid4().hex[:6]}"
    script = f"""
set -eu
curl -fsSL -o /tmp/syft.tgz https://github.com/anchore/syft/releases/download/v1.18.1/syft_1.18.1_linux_amd64.tar.gz
tar -C /tmp -xzf /tmp/syft.tgz
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
AUTH=$(printf 'serviceaccount:%s' "$TOKEN" | base64 -w0)
mkdir -p /tmp/docker
printf '%s' "{{\\"auths\\":{{\\"{registry}\\":{{\\"auth\\":\\"$AUTH\\"}}}}}}" > /tmp/docker/config.json
export DOCKER_CONFIG=/tmp/docker
export SYFT_REGISTRY_INSECURE_USE_HTTP=true
/tmp/syft "registry:{image}" -o cyclonedx-json
"""
    return {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {"name": name, "namespace": namespace},
        "spec": {
            "backoffLimit": 1,
            "ttlSecondsAfterFinished": 600,
            "template": {
                "spec": {
                    "restartPolicy": "Never",
                    "serviceAccountName": os.getenv("AGENT_SA_BUILDER", os.getenv("BUILDER_SA", "acs-agent-builder")),
                    "containers": [
                        {
                            "name": "syft",
                            "image": "registry.access.redhat.com/ubi9/ubi:latest",
                            "command": ["/bin/bash", "-lc", script],
                            "securityContext": {
                                "runAsNonRoot": True,
                                "runAsUser": 1001,
                                "allowPrivilegeEscalation": False,
                                "capabilities": {"drop": ["ALL"]},
                            },
                        }
                    ],
                }
            },
        },
    }


async def _wait_build(namespace: str, name: str, timeout: int = 1200) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        body = await k8s_apply(
            "GET", f"/apis/build.openshift.io/v1/namespaces/{namespace}/builds/{name}"
        )
        phase = str((body.get("status") or {}).get("phase") or "")
        if phase == "Complete":
            return
        if phase in {"Failed", "Error", "Cancelled"}:
            raise RuntimeError(f"build {name} {phase}")
        await asyncio.sleep(10)
    raise TimeoutError(f"build {name} did not finish")


async def _wait_job(namespace: str, name: str, timeout: int = 900) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        body = await k8s_apply("GET", f"/apis/batch/v1/namespaces/{namespace}/jobs/{name}")
        status = body.get("status") or {}
        if status.get("succeeded"):
            pods = await k8s_apply(
                "GET",
                f"/api/v1/namespaces/{namespace}/pods?labelSelector=job-name%3D{name}",
            )
            items = pods.get("items") or []
            if not items:
                raise RuntimeError(f"sbom job {name} succeeded without a pod")
            pod = items[0]["metadata"]["name"]
            log = await k8s_apply(
                "GET", f"/api/v1/namespaces/{namespace}/pods/{pod}/log?container=syft"
            )
            if isinstance(log, dict) and "raw" in log:
                return str(log["raw"])
            return json.dumps(log)
        if status.get("failed"):
            raise RuntimeError(f"sbom job {name} failed")
        await asyncio.sleep(8)
    raise TimeoutError(f"sbom job {name} did not finish")


def _parse_sbom(raw: str) -> dict[str, Any]:
    start = raw.find("{")
    end = raw.rfind("}")
    if start < 0 or end <= start:
        raise RuntimeError("syft did not emit a CycloneDX document")
    parsed = json.loads(raw[start : end + 1])
    if not isinstance(parsed, dict):
        raise RuntimeError("syft document was not an object")
    return parsed


async def _upload_sbom(dest: str, sbom: dict[str, Any]) -> None:
    base = os.getenv("TPA_URL", "").strip().rstrip("/")
    if not base:
        raise RuntimeError("TPA_URL is unset; refusing to publish an unscanned image")
    headers = {"Content-Type": "application/json"}
    token = os.getenv("TPA_TOKEN", "").strip()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    async with httpx.AsyncClient(verify=False, timeout=60.0) as client:
        response = await client.put(
            f"{base}/api/v1/sbom",
            params={"id": dest},
            json=sbom,
            headers=headers,
        )
        if response.status_code >= 400:
            response = await client.post(f"{base}/api/v1/sbom", json=sbom, headers=headers)
        response.raise_for_status()


async def _gate_and_rollout(dest: str) -> dict[str, Any]:
    namespace = os.getenv("BUILDER_NAMESPACE", "acs-agent-builder")
    created = await start_buildconfig(dest)
    build_name = str((created.get("metadata") or {}).get("name") or "")
    if not build_name or created.get("dryRun"):
        return {"target": dest, "status": "dry-run", "build": build_name}
    await _wait_build(namespace, build_name)
    job = _sbom_job(dest, _runtime_image(dest))
    job_name = job["metadata"]["name"]
    await k8s_apply("POST", f"/apis/batch/v1/namespaces/{namespace}/jobs", job)
    raw = await _wait_job(namespace, job_name)
    sbom = _parse_sbom(raw)
    blocked = _disallowed_components(sbom)
    if blocked:
        raise RuntimeError(
            "Trusted Profile Analyzer rejected packages: " + ", ".join(sorted(set(blocked)))
        )
    await _upload_sbom(dest, sbom)
    rollouts = []
    for method, path, body in _sandbox_manifests(dest):
        applied = await k8s_apply(method, path, body)
        rollouts.append(
            {
                "kind": body.get("kind"),
                "name": body.get("metadata", {}).get("name"),
                "dryRun": applied.get("dryRun", False),
            }
        )
    return {
        "target": dest,
        "status": "rolled-out",
        "build": build_name,
        "sbom": job_name,
        "rollout": rollouts,
    }


async def notify_mattermost(text: str) -> None:
    url = os.getenv("MATTERMOST_WEBHOOK_URL", "").strip()
    if not url:
        return
    async with httpx.AsyncClient(timeout=15.0, verify=False) as client:
        await client.post(url, json={"text": text, "username": "acs-agent-builder"})


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok", "role": "builder"}


async def _run_rebuild(job_id: str, spec: dict[str, Any]) -> None:
    results: list[dict[str, Any]] = []
    _STATUS[job_id]["status"] = "running"
    for target in spec.get("targets") or []:
        dest = str(target.get("to") or "remediated-rosey")
        try:
            item = await _gate_and_rollout(dest)
        except Exception as exc:
            item = {"target": dest, "status": "failed", "error": str(exc)}
        results.append(item)
        _STATUS[job_id]["targets"] = results
    failed = [item for item in results if item.get("status") == "failed"]
    _STATUS[job_id]["status"] = "failed" if failed else "rolled-out"
    summary = "**Agentic builder** TPA gate: " + ", ".join(
        f"{item.get('target')}={item.get('status')}" for item in results
    )
    try:
        await notify_mattermost(summary)
    except Exception:
        pass


@app.get("/rebuild/status")
def rebuild_status() -> dict[str, Any]:
    return {"jobs": _STATUS}


@app.post("/rebuild")
async def rebuild(spec: dict[str, Any]) -> dict[str, Any]:
    job_id = uuid.uuid4().hex[:12]
    _STATUS[job_id] = {"status": "accepted", "targets": [], "spec": spec}
    task = asyncio.create_task(_run_rebuild(job_id, spec))
    _TASKS.add(task)
    task.add_done_callback(_TASKS.discard)
    return {"id": job_id, "status": "accepted", "spec": spec}


def run() -> None:
    import uvicorn

    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8080"))
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    run()
