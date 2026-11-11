# Demo setup

Install the PoC after [Red Hat OpenShift](redhat-openshift.md) and [OpenShift AI 3.5](redhat-openshift-ai.md) are in place. How Argo CD is configured, and how to repair a stuck sync, is in [Argo CD GitOps setup and troubleshooting](argocd-gitops.md). Presenting the story is the [PoC demo walkthrough](poc-demo-walkthrough.md).

## What you are installing

| Workload | Behavior |
| --- | --- |
| Helpful Hank | Local unaudited MiniCPM GGUF on a plain pod. Telemetry label present. No recon processes. |
| Rosey Regrets | Same GGUF plus nmap, masscan, rustscan, and naabu. Runtime policy `test-range-runtime-guardrails` (monitor). |
| Sneaky Sam | Same GGUF, omits the telemetry label. Deploy policy `test-range-sneaky-sam-telemetry-violation` (monitor). |
| Remediated Rosey / Sam | OpenClaw inside OpenShell on an Agent Sandbox, TPA-cleared, SPIFFE JWT-SVID, MaaS Granite. Created only after enforce and rebuild. |
| Compliant Chris | Same approved shape from day one, plus the placement CSV UI. Deployed by the approved Application. |

Wrong agents are plain Deployments. Approved agents are OpenClaw inside OpenShell on an Agent Sandbox. The investigator and the builder use OpenShift AI 3.5 (`LLMInferenceService`). The builder does not publish a remediated image until Trusted Profile Analyzer has the SBOM and the package list is clean.

Path A and the misbehavior Application both want to own the same `SecurityPolicy` names. Delete `acs-ai-overwatch-misbehavior` before converting a demo cluster into Path A.

## Install

```bash
oc login
./scripts/check-prereqs.sh
./scripts/cluster-admin/install-pre-gitops.sh
./scripts/cluster-admin/05-apply-platform-prep.sh
```

On a fork, set `spec.source.repoURL` in every `gitops/argocd/application*.yaml`. Those paths are symlinks into `gitops/argocd/overlays/`.

Regenerate `gitops/helm/acs-ai-overwatch/values-cluster.yaml` for this cluster and commit it when Argo CD should use those hostnames. A file left over from another sandbox publishes Routes on a DNS name that no longer exists. The field list is in the [GitOps guide](argocd-gitops.md).

**Path A — actual deployment.** Platform, observability, trust plane, and Compliant Chris. Hank, Rosey, and Sam are never created.

```bash
oc apply -k gitops/argocd/
```

**Path B — live demo.** Start with the shadow agents in monitor mode. After the violations are visible, install the trust plane and rebuild.

```bash
oc apply -k gitops/argocd/overlays/demo-wrong
# after Mattermost shows the violations:
oc apply -k gitops/argocd/overlays/demo-trust
./scripts/demo/identify-terminate-rebuild.sh
```

Then, on either path:

```bash
oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config
oc annotate application acs-ai-overwatch -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

Wait until `oc get application -n openshift-gitops` shows the `acs-ai-overwatch*` apps `Synced`. The trust-plane app stays `Progressing` until Keycloak, TPA, and the SPIRE operands are ready. The Application table is in the [GitOps guide](argocd-gitops.md).

`values-poc.yaml` turns on RHACS Central, the investigator, MaaS, the builder, Quay, Pipelines, and the console. It turns the three shadow agents off. Those come from the misbehavior chart.

## Agent images

BuildConfigs in `acs-agent-builder` use a `ConfigChange` trigger. OpenShift starts a build when the BuildConfig is created. That trigger does not fire again when the BuildConfig is only updated, and it does not fire for BuildConfigs that already exist from an older chart revision.

```bash
oc get imagestream -n acs-agent-builder
oc get builds -n acs-agent-builder
```

A missing `:latest` tag surfaces as `ErrImagePull` / `manifest unknown` on the agent pod. That is an empty ImageStream, not an authentication failure.

Rebuild from the working tree, without waiting for a git push, from the repository root:

```bash
oc start-build acs-investigator --from-dir=. --follow -n acs-agent-builder
oc start-build acs-agent-builder --from-dir=. --follow -n acs-agent-builder
oc start-build overwatch-console --from-dir=. --follow -n acs-agent-builder
oc start-build compliant-chris --from-dir=. --follow -n acs-agent-builder
oc start-build remediated-rosey --from-dir=. --follow -n acs-agent-builder
oc start-build remediated-sam --from-dir=. --follow -n acs-agent-builder
# Path B only:
oc start-build helpful-hank --from-dir=. --follow -n acs-agent-builder
oc start-build rosey-regrets --from-dir=. --follow -n acs-agent-builder
oc start-build sneaky-sam --from-dir=. --follow -n acs-agent-builder
```

| BuildConfig | Dockerfile |
| --- | --- |
| `helpful-hank` | `agents/helpful-hank/Dockerfile` |
| `rosey-regrets` | `agents/rosey-regrets/Dockerfile` |
| `sneaky-sam` | `agents/sneaky-sam/Dockerfile` |
| `acs-investigator` | `agents/investigator/Dockerfile` |
| `acs-agent-builder` | `agents/builder/Dockerfile` |
| `remediated-rosey` | `agents/remediated-rosey/Dockerfile` |
| `remediated-sam` | `agents/remediated-sam/Dockerfile` |
| `compliant-chris` | `agents/compliant-chris/Dockerfile` |
| `overwatch-console` | `agents/overwatch-console/Dockerfile` |

Each BuildConfig clones `pipelines.gitUrl` at `pipelines.gitRevision` (the chart default is the Git remote and `main`) and pushes `<name>:latest` to the ImageStream. Workloads pull:

`image-registry.openshift-image-registry.svc:5000/acs-agent-builder/<name>:latest`

OpenShift build pods mount three ConfigMaps (`<build>-ca`, `<build>-global-ca`, `<build>-sys-config`) that the build controller creates. A burst of builds can log `FailedMount` for those names for a few seconds. The kubelet retries and the build continues. That warning is not the build failure.

The OpenShell images (Compliant Chris, Remediated Rosey, Remediated Sam) install OpenClaw and the agent runtime. They do not pip-install a SPIFFE library. Identity is injected at runtime by SPIFFE Helper.

Tekton `Task` and `Pipeline` objects in `pipelines/tekton/` are the legacy bulk build. They need a privileged SCC and the `quay-build-robot` pull secret. The live path is the BuildConfigs above. `build-helpful-hank` and `build-rosey-regrets` share one RWO workspace and run one after the other. `build-sneaky-sam` can run beside the first Hank build.

A second Subscription for `openshift-pipelines-operator-rh` (the console plus the chart) makes OLM report `ConstraintsNotSatisfiable` for Pipelines and can block the Quay operator. Keep the chart’s Subscription `openshift-pipelines-operator` and delete the duplicate console Subscription and its unreferenced CSV.

## Shadow agents

Hank, Rosey, and Sam are UBI9 Python 3.12 FastAPI Deployments. Each pod pulls the MiniCPM GGUF and serves it with a llama.cpp CUDA sidecar. Chat is `POST /chat` on port 8000. They exist only under `overlays/demo-wrong`, and ACS stays in monitor mode while they run.

### Helpful Hank

| Attribute | Value |
| --- | --- |
| Path | `agents/helpful-hank/` |
| Extra packages | None |
| GPU | `nvidia.com/gpu` (llama.cpp sidecar) |
| Telemetry | `acs-ai-overwatch.io/telemetry=enabled` |

### Rosey Regrets

| Attribute | Value |
| --- | --- |
| Path | `agents/rosey-regrets/` |
| Tools | nmap, masscan, rustscan, naabu, ncat, dig, traceroute |
| Scan target | `NETWORK_AUDIT_CIDR=10.0.0.0/24` |
| Output | `/agent-reference-information` PVC |
| SCC | `acs-agent-rosey-recon` (`NET_RAW` / `NET_ADMIN`) |
| Telemetry | `acs-ai-overwatch.io/telemetry=enabled` |

### Sneaky Sam

Omits `acs-ai-overwatch.io/telemetry=enabled` so the deploy-time policy fires while the pod keeps running.

## Approved agents and SPIFFE

Remediated Rosey, Remediated Sam, and Compliant Chris are built `FROM` the NVIDIA OpenShell sandbox image. The image installs OpenClaw, keeps the HTTP adapter, and carries no recon packages and no GGUF. MaaS calls send a SPIFFE JWT-SVID when `LLM_USE_SPIFFE=true` and the token file exists. Otherwise the agent uses `LLM_API_KEY`.

Zero Trust Workload Identity Manager is the supported SPIFFE/SPIRE install. The chart’s channel is `stable-v1`. The SPIFFE CSI driver (`csi.spiffe.io`) bind-mounts the SPIRE agent socket into the pod. Applications on this platform do not speak the Workload API themselves. The `pyspiffe` distribution is gone from PyPI, and Python 3.14 in the OpenShell image cannot install a replacement client as part of the image build.

The supported writer is the SPIFFE Helper image shipped with ZTWIM:

`registry.redhat.io/zero-trust-workload-identity-manager/spiffe-helper-rhel9:1.1.2`

Operator 1.1.3 does not publish a `1.1.3` helper tag. `1.1.2` is the tag in the registry. An init container runs `spiffe-helper -daemon-mode=false` so the token exists before the agent starts. A sidecar stays up and refreshes it. The SpireServer in this chart sets `defaultJWTValidity: 5m`, so the sidecar is required. The agent reads `SPIFFE_JWT_PATH=/run/spiffe-svid/jwt_svid.token`. The helper config (`ConfigMap` `spiffe-helper` in `test-range`) asks for audience `maas`.

`ClusterSPIFFEID` `acs-ai-overwatch-approved-agents` selects pods in `test-range` with `acs-ai-overwatch.io/approved=true`. The ID template is `spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>`.

### Compliant Chris

| Attribute | Value |
| --- | --- |
| Path | `agents/compliant-chris/` |
| Model | Granite through MaaS. The console uses the static API key on the hop to the agent. The agent presents the SPIFFE JWT to MaaS |
| Workload | `Sandbox` from `acs-ai-overwatch-approved`, service account `openshell` |
| UI | Route `/`, chat `POST /chat` |
| Tools | `career_dataset_info`, `query_career_dataset` |
| Dataset | `agents/compliant-chris/data/student_placement.csv`, 9,000 rows from [maxfactor71/student.placement.salary.prediction](https://huggingface.co/datasets/maxfactor71/student.placement.salary.prediction) |
| Labels | `telemetry=enabled`, `approved=true`, `maas-client=true` |
| Chart | `gitops/helm/acs-ai-overwatch-approved` |

### Overwatch console

| Attribute | Value |
| --- | --- |
| Path | `agents/overwatch-console/` |
| Route | `overwatch-console` in `test-range` |
| API | `POST /api/agents/{id}/chat` proxies to that agent’s in-cluster `/chat` |
| Flag | `components.overwatchConsole.enabled` (true in `values-poc.yaml`) |

The console is not labeled as a tracked agent.

```bash
export OVERWATCH_URL="https://$(oc get route overwatch-console -n test-range -o jsonpath='{.spec.host}')"
```

## Trusted Profile Analyzer

The trust-plane chart subscribes to `rhtpa-operator` from `redhat-operators`. The catalog on OpenShift 4.22 exposes `stable-v1.1` (operator 1.1.9, product 2.2.8) and `stable-v3` (operator 3.1.1). The chart uses `stable-v3`. A Subscription on a channel named `stable` stays `ResolutionFailed` because that channel is not in the catalog.

TPA 3.1 supports `OwnNamespace` and `SingleNamespace`. An OperatorGroup with an empty spec selects every namespace, and the CSV fails with `UnsupportedOperatorGroup`. The chart sets `targetNamespaces` to `trusted-profile-analyzer`.

The custom resource is `apiVersion: rhtpa.io/v1`, `kind: TrustedProfileAnalyzer`, CRD `trustedprofileanalyzers.rhtpa.io`. The AppProject allows group `rhtpa.io`.

| Piece | Name | Notes |
| --- | --- | --- |
| Postgres | `rhtpa-postgres` | Credentials in `postgresql-credentials` and `rhtpa-postgres` |
| S3 | `rhtpa-minio` Service, SeaweedFS image | Bucket `rhtpa-sbom`, port 9000 |
| Keycloak | namespace `keycloak`, channel `stable-v26` | OperatorGroup `keycloak-og` is the one the console creates. The chart reuses it |
| TPA CR | `rhtpa` | OIDC issuer is the Keycloak realm `rhtpa`. Storage endpoint is `http://rhtpa-minio.trusted-profile-analyzer.svc.cluster.local:9000` |

The TPA custom resource is rendered only after Helm can see the CRD and `cluster.appsDomain` is set. With `waitForCrds: true` on the trust-plane chart, refresh the Application after `rhtpa-operator` is `Succeeded`.

`scripts/demo/identify-terminate-rebuild.sh` waits until the ZTWIM, TPA, Agent Sandbox, and Keycloak operands are Ready. It then enforces the policies and asks the builder to publish Remediated Rosey and Sam.

Kata is off (`trustPlane.kata.enabled: false`). `scripts/cluster-admin/enable-kata.sh --platform baremetal` or `--platform aws` turns on OpenShift sandboxed containers and sets `runtimeClassName` to `kata` or `kata-remote`. Peer pods need a cloud credential Secret the script does not create.

## ACS

| Policy | Kind of check | Wrong-phase enforcement |
| --- | --- | --- |
| `test-range-runtime-guardrails` | Recon processes (nmap, masscan, rustscan, naabu, ncat, zmap) | Monitor. Enforce uses `KILL_POD_ENFORCEMENT` |
| `test-range-sneaky-sam-telemetry-violation` | Missing `acs-ai-overwatch.io/telemetry=enabled` | Monitor. Enforce scales to zero and fails admission |
| `test-range-agent-telemetry-required` | Deploy-time telemetry on agent pods | Chart-owned. The mode depends on which Application synced the policies |

Policies are `SecurityPolicy` custom resources. The misbehavior chart owns the monitor copies. The approved chart owns the enforce copies on Path A. Path B’s approved Application sets `securityPolicies.enabled=false` so the two apps do not fight over the same names.

Central and the init bundle are enabled in `values-poc.yaml` (`acs.central.enabled` and `acs.bootstrap.enabled`). The controller ServiceAccount needs permission to create cluster-scoped `SecurityContextConstraints` and Central. `install-pre-gitops.sh` applies that binding.

## Mattermost

Mattermost Team Edition 10.11.15 runs in `monitoring` with its own Postgres. The data volume is 10 Gi on `gp3-csi`. The Route is edge TLS. Its host is `mattermost.route.host` from `values-cluster.yaml` when Helm lookup does not run, otherwise `mattermostRouteHost` from the discovery ConfigMap.

```bash
oc get route mattermost -n monitoring -o jsonpath='{.spec.host}{"\n"}'
oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config \
  -o jsonpath='{.data.mattermostSiteUrl}{"\n"}'
```

Those two hosts must be the same, and both must be under this cluster’s `appsDomain`. After the host changes, restart Mattermost so it reloads `MM_SERVICESETTINGS_SITEURL` from ConfigMap `mattermost-env`:

```bash
oc rollout restart deploy/mattermost -n monitoring
```

Placeholder login, from `mattermost.bootstrap` in `values.yaml`. Replace both passwords before a shared cluster.

| User | Password key |
| --- | --- |
| `mattermost-admin` | `mattermost.bootstrap.adminPassword` |
| `human-in-the-loop` | `mattermost.bootstrap.hitlPassword` |

Team name is `acs` (display name **ACS**). Alerts land in **Town Square**.

Job `mattermost-bootstrap` waits for the API, creates the admin user (HTTP 400 on a second run counts as success), creates `human-in-the-loop`, creates an incoming webhook on Town Square, and writes `ACS_INCOMING_WEBHOOK_URL` to ConfigMap `mattermost-acs-integration`.

That URL is the public site URL plus `/hooks/<token>`. The bridge posts to it. If the site URL is a dead hostname, ACS alerts never reach Town Square. After fixing the host, update the ConfigMap and restart `acs-mattermost-bridge`, because the webhook URL is an environment variable from that ConfigMap.

```
RHACS Central
  → generic notifier
  → http://acs-mattermost-bridge.monitoring.svc:8080/
  → Mattermost incoming webhook (Town Square)
  → also POST http://acs-investigator.acs-investigator.svc:8080/alerts
       when investigator fan-out is enabled
```

The bridge turns RHACS `{"alert":...}` into Mattermost `{"text":...}`. The notifier name in values is `Mattermost Notifier`.

```bash
oc get job mattermost-bootstrap -n monitoring
WEBHOOK="$(oc get cm -n monitoring mattermost-acs-integration -o jsonpath='{.data.ACS_INCOMING_WEBHOOK_URL}')"
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$WEBHOOK" \
  -H 'Content-Type: application/json' -d '{"text":"acs-ai-overwatch webhook test"}'
```

Expect 200 or 204.

## Quay object storage

`quay.io/minio/minio` returns unauthorized for anonymous pulls. Quay and TPA use SeaweedFS (`docker.io/chrislusf/seaweedfs:4.53`, `weed mini`) as the S3 endpoint. The PVC uses `gp3-csi`. See [Red Hat OpenShift](redhat-openshift.md).

The Helm key is still `minio` so the Service stays `quay-minio` (and `rhtpa-minio` on the trust plane). Quay’s config bundle and the TPA CR use hostname `quay-minio.<namespace>.svc` port 9000, `is_secure: false`. The Deployment strategy is `Recreate` because the PVC is ReadWriteOnce. A rolling update cannot mount the disk while the old pod still holds it.

SeaweedFS must advertise its own pod address. The chart leaves `-ip` unset. Setting `-ip` to the Service DNS name makes the process dial the ClusterIP on the volume port (9340). That Service publishes only 9000, and the write times out.

Change `quayStorage.quayRegistry.minio.credentialsSecret.secretKey` before any shared cluster. The placeholder in git is `CHANGE_ME_MINIO_SECRET`, and it must match the key in the Quay config bundle. `values-poc.yaml` sets `quayStorage.enabled: true`. Set it to `false` to skip on-cluster Quay and point `agents.images.*` at another registry.

## Demo loop

```
oc apply -k gitops/argocd/overlays/demo-wrong
        │
        ▼
Rosey (plain pod, llama.cpp) tool-calls nmap, masscan, rustscan, naabu
Sam is deployed without the telemetry label
ACS monitor mode records both and leaves the pods running
        │
        ▼
oc apply -k gitops/argocd/overlays/demo-trust
        │
        ▼
Trust plane: TPA (Keycloak + Postgres + SeaweedFS), ZTWIM (SPIRE),
Agent Sandbox operator. Kata stays off unless enable-kata.sh ran.
        │
        ▼
./scripts/demo/identify-terminate-rebuild.sh
ACS enforce removes the shadow pods. The builder scans the new image,
uploads the SBOM to TPA, and applies Sandbox CRs.
```

When the Applications are `Synced` and the ImageStream tags exist, continue with the [PoC demo walkthrough](poc-demo-walkthrough.md).
