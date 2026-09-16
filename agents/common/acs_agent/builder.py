"""Agentic container builder: turn an investigator rebuild spec into OpenShift PipelineRuns."""

from __future__ import annotations

import json
import os
import uuid
from typing import Any

import httpx
from fastapi import FastAPI

app = FastAPI(title="ACS Agentic Builder", version="0.5.0")


def _pipeline_run(target: dict[str, Any]) -> dict[str, Any]:
    registry = os.getenv("IMAGE_REGISTRY", "quay-quay-app.quay.svc.cluster.local:80")
    org = os.getenv("IMAGE_ORG", "acs-agents")
    tag = os.getenv("IMAGE_TAG", "latest")
    git_url = os.getenv("GIT_REPO_URL", "")
    git_revision = os.getenv("GIT_REVISION", "main")
    dest = target.get("to") or "remediated-rosey"
    dockerfile = (
        "agents/remediated-rosey/Dockerfile"
        if "rosey" in dest
        else "agents/remediated-sam/Dockerfile"
    )
    return {
        "apiVersion": "tekton.dev/v1",
        "kind": "PipelineRun",
        "metadata": {
            "generateName": f"remediate-{dest}-",
            "namespace": os.getenv("BUILDER_NAMESPACE", "acs-agent-builder"),
            "labels": {
                "app.kubernetes.io/part-of": "acs-ai-overwatch",
                "acs-ai-overwatch.io/remediated": "true",
                "acs-ai-overwatch.io/target": dest,
            },
        },
        "spec": {
            "pipelineRef": {"name": "build-remediated-agents"},
            "params": [
                {"name": "git-url", "value": git_url},
                {"name": "git-revision", "value": git_revision},
                {"name": "dockerfile", "value": dockerfile},
                {
                    "name": "image",
                    "value": f"{registry}/{org}/{dest}:{tag}",
                },
                {"name": "push-tls-verify", "value": "false"},
            ],
            "workspaces": [
                {
                    "name": "shared-source",
                    "volumeClaimTemplate": {
                        "spec": {
                            "accessModes": ["ReadWriteOnce"],
                            "resources": {"requests": {"storage": "10Gi"}},
                        }
                    },
                }
            ],
        },
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
        return response.json()


async def create_pipeline_run(manifest: dict[str, Any]) -> dict[str, Any]:
    namespace = manifest["metadata"].get("namespace", "acs-agent-builder")
    return await k8s_apply(
        "POST",
        f"/apis/tekton.dev/v1/namespaces/{namespace}/pipelineruns",
        manifest,
    )


def _remediated_manifests(dest: str) -> list[tuple[str, str, dict[str, Any]]]:
    namespace = os.getenv("TEST_RANGE_NAMESPACE", "test-range")
    registry = os.getenv("IMAGE_REGISTRY", "quay-quay-app.quay.svc.cluster.local:80")
    org = os.getenv("IMAGE_ORG", "acs-agents")
    tag = os.getenv("IMAGE_TAG", "latest")
    port = int(os.getenv("AGENTS_SERVICE_PORT", "8000"))
    sa = os.getenv("AGENT_SA", "acs-agent")
    image = f"{registry}/{org}/{dest}:{tag}"
    labels = {
        "app.kubernetes.io/name": dest,
        "app.kubernetes.io/component": "agent",
        "app.kubernetes.io/part-of": "acs-ai-overwatch",
        "acs-ai-overwatch.io/remediated": "true",
        "acs-ai-overwatch.io/telemetry": "enabled",
    }
    deployment = {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {"name": dest, "namespace": namespace, "labels": labels},
        "spec": {
            "replicas": 1,
            "selector": {"matchLabels": {"app.kubernetes.io/name": dest}},
            "template": {
                "metadata": {"labels": labels},
                "spec": {
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
                                {"name": "AGENT_ENABLE_NETWORK_AUDIT", "value": "false"},
                                {
                                    "name": "LLM_API_BASE",
                                    "value": os.getenv("MAAS_API_BASE", ""),
                                },
                                {
                                    "name": "LLM_MODEL",
                                    "value": os.getenv(
                                        "MAAS_MODEL", "granite-3.1-8b-instruct-fp8"
                                    ),
                                },
                                {
                                    "name": "LLM_API_KEY",
                                    "valueFrom": {
                                        "secretKeyRef": {
                                            "name": os.getenv(
                                                "MAAS_API_KEY_SECRET", "maas-poc-api-key"
                                            ),
                                            "key": "api-key",
                                        }
                                    },
                                },
                            ],
                            "ports": [{"name": "http", "containerPort": port}],
                            "readinessProbe": {
                                "httpGet": {"path": "/healthz", "port": "http"},
                            },
                        }
                    ],
                },
            },
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
            f"/apis/apps/v1/namespaces/{namespace}/deployments/{dest}",
            deployment,
        ),
        ("PATCH", f"/api/v1/namespaces/{namespace}/services/{dest}", service),
    ]


async def notify_mattermost(text: str) -> None:
    url = os.getenv("MATTERMOST_WEBHOOK_URL", "").strip()
    if not url:
        return
    async with httpx.AsyncClient(timeout=15.0, verify=False) as client:
        await client.post(url, json={"text": text, "username": "acs-agent-builder"})


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok", "role": "builder"}


@app.post("/rebuild")
async def rebuild(spec: dict[str, Any]) -> dict[str, Any]:
    results = []
    for target in spec.get("targets") or []:
        dest = str(target.get("to") or "remediated-rosey")
        manifest = _pipeline_run(target)
        item: dict[str, Any] = {"target": dest}
        try:
            created = await create_pipeline_run(manifest)
            item["pipelineRun"] = created.get("metadata", {}).get("name") or (
                f"dry-run-{uuid.uuid4().hex[:8]}"
            )
            item["status"] = "submitted"
        except Exception as exc:
            item["error"] = str(exc)
        rollouts = []
        for method, path, body in _remediated_manifests(dest):
            try:
                applied = await k8s_apply(method, path, body)
                rollouts.append(
                    {
                        "kind": body.get("kind"),
                        "name": body.get("metadata", {}).get("name"),
                        "dryRun": applied.get("dryRun", False),
                    }
                )
            except Exception as exc:
                rollouts.append({"kind": body.get("kind"), "error": str(exc)})
        item["rollout"] = rollouts
        results.append(item)
    summary = "**Agentic builder** submitted OpenShift PipelineRuns: " + ", ".join(
        f"{item.get('target')}={item.get('pipelineRun') or item.get('error')}" for item in results
    )
    try:
        await notify_mattermost(summary)
    except Exception:
        pass
    return {"spec": spec, "pipelineRuns": results}


def run() -> None:
    import uvicorn

    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8080"))
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    run()
