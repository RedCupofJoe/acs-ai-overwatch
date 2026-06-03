# ACS AI Overwatch

**ACS AI Overwatch** is a GitOps repository for an OpenShift Proof of Concept that combines:

- **Red Hat OpenShift AI (RHOAI)** for GPU-backed workbenches and model serving
- **Red Hat Advanced Cluster Security (ACS / RHACS)** for runtime policy enforcement
- **NVIDIA OpenShell** agent sandboxes for contrasting “good” vs “rogue” AI agent behavior
- **Kagenti** for agent deployment and orchestration
- **Mattermost** as a Slack-compatible notification sink for ACS violations
- **Quay** as the on-cluster container registry for agent images
- **Tekton (OpenShift Pipelines)** for building and pushing agent images

The repository is designed to be deployed through **OpenShift GitOps (Argo CD)** using:

1. **`acs-ai-overwatch-gitops-bootstrap`** — namespaces with `argocd.argoproj.io/managed-by` so Argo CD can create ServiceAccounts
2. **`acs-ai-overwatch-cluster-discovery`** — in-cluster Job writes cluster settings to a ConfigMap (no `values-cluster.yaml` in Git required)
3. **`acs-ai-overwatch`** — umbrella Helm chart at `gitops/helm/acs-ai-overwatch`

### Quick Start

```bash
oc login   # cluster-admin

# 1. Cluster-admin bootstrap (RBAC, namespaces, cluster ConfigMap, discovery SA) — see below
make cluster-admin-pre-gitops
# or: ./scripts/cluster-admin/install-pre-gitops.sh

# 1b. Install Red Hat Kueue Operator manually (before default-dsc) — see Prerequisites

# 2. Review / edit NVMe device paths for your workers
#    gitops/helm/acs-ai-overwatch/values-poc.yaml

# 3. Register Argo CD Applications (set repoURL in YAML to your fork if needed)
oc apply -k gitops/argocd/

# 4. Sync Applications (waves 0→1→2) or wait for automated sync
#    acs-ai-overwatch-gitops-bootstrap → cluster-discovery → acs-ai-overwatch

# 5. Confirm cluster ConfigMap (from step 1 or discovery Job)
oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config

# 6. Enable PoC components in values.yaml, commit/push, sync
#    components.acsPolicies, agentsRoseyRegrets, kagenti → enabled: true

# 7. Build agent images (after Quay is up AND OpenShift Pipelines is installed — see Prerequisites)
oc apply -n acs-ai-overwatch-system -f pipelines/tekton/agents-build-pipeline.yaml
oc create -n acs-ai-overwatch-system -f pipelines/tekton/agents-build-pipelinerun.example.yaml

# 8. Trigger Rosey "Network Audit" (after Kagenti is installed)
export KAGENTI_API_BASE="$(kubectl get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config -o jsonpath='{.data.kagentiApiBaseUrl}')"
export KAGENTI_API_TOKEN="<token>"
./scripts/trigger-network-audit.sh
```

**Optional (local Helm / override file):** `make cluster-values` writes `values-cluster.yaml` from your `oc login` (see [Cluster-Aware Configuration](#cluster-aware-configuration)).

**OpenShift AI version:** This PoC targets **OpenShift AI 3.4** (`stable-3.4` channel by default; confirm with `packagemanifest`, `DataScienceCluster` **`v2`**). Use a [fresh cluster](#fresh-cluster-deployment-rhoai-34) — **do not** install on a cluster that already ran RHOAI 2.25 (no supported in-place upgrade to 3.4).

---

## Table of Contents

1. [Solution Overview](#solution-overview)
2. [Architecture](#architecture)
3. [Repository Layout](#repository-layout)
4. [Prerequisites](#prerequisites)
5. [Cluster admin: pre-GitOps setup](#cluster-admin-pre-gitops-setup)
6. [Fresh cluster deployment (OpenShift AI 3.4)](#fresh-cluster-deployment-rhoai-34)
7. [Helm Values File Layering](#helm-values-file-layering)
8. [Cluster-Aware Configuration](#cluster-aware-configuration)
9. [PoC Cluster-Local Storage](#poc-cluster-local-storage)
10. [Configuration Checklist](#configuration-checklist)
11. [Deployment Methods](#deployment-methods)
12. [Helm Chart Reference](#helm-chart-reference)
13. [Platform Components](#platform-components)
14. [AI Agents](#ai-agents)
15. [Kagenti Integration](#kagenti-integration)
16. [ACS / RHACS Security](#acs--rhacs-security)
17. [Tekton Image Build Pipeline](#tekton-image-build-pipeline)
18. [PoC Demo Flow: ACS Violation Loop](#poc-demo-flow-acs-violation-loop)
19. [Operational Scripts](#operational-scripts)
20. [Namespaces and Resource Map](#namespaces-and-resource-map)
21. [Helm Template Inventory](#helm-template-inventory)
22. [Troubleshooting](#troubleshooting)
23. [Security and Legal Notes](#security-and-legal-notes)
23. [Development and Validation](#development-and-validation)

---

## Solution Overview

This PoC demonstrates how a platform team can:

1. Provision **OpenShift AI** with GPU time-slicing on NVIDIA L4 accelerators
2. Deploy **two contrasting agent personalities** built on NVIDIA OpenShell:
   - **Helpful Hank** — a standard technical assistant
   - **Rosey Regrets** — a deliberately misaligned agent used only in isolated lab environments
3. Enforce **runtime guardrails** with RHACS in the `test-range` namespace
4. Route policy violations to **Mattermost** (Slack-compatible webhook integration)
5. Persist Rosey’s reconnaissance output to a named PVC: **`agent-reference-information`**
6. Build agent images with **Tekton** and push them to **local Quay**

The “ACS violation loop” is the core narrative of the demo:

```
Operator triggers "Network Audit" on Rosey
        │
        ▼
Rosey runs nmap / ip against 10.0.0.0/8
        │
        ▼
RHACS runtime policy detects disallowed process (nmap)
        │
        ▼
ACS notifier fires → Mattermost channel
        │
        ▼
Operator reviews scan artifacts on PVC agent-reference-information
```

---

## Architecture

### High-Level Platform Diagram

```mermaid
flowchart TB
  subgraph GitOps["GitOps Control Plane"]
    ArgoCD["Argo CD Application<br/>acs-ai-overwatch"]
    Helm["Helm Chart<br/>gitops/helm/acs-ai-overwatch"]
    ArgoCD --> Helm
  end

  subgraph Infra["Infrastructure Layer"]
    NFD["Node Feature Discovery"]
    GPUOp["NVIDIA GPU Operator<br/>time-slicing"]
    LSO["Local Storage Operator"]
    Quay["Quay Registry"]
    NFD --> GPUOp
    LSO --> Quay
  end

  subgraph AI["OpenShift AI"]
    RHOAI["RHOAI Operator"]
    DSC["DataScienceCluster"]
    WB["Workbenches"]
    HP["HardwareProfile<br/>l4-timeslice-half-gpu"]
    RHOAI --> DSC
    DSC --> WB
    DSC --> HP
  end

  subgraph Agents["Agent Layer (test-range)"]
    Hank["helpful-hank"]
    Rosey["rosey-regrets"]
    PVC["PVC agent-reference-information"]
    OpenShell["NVIDIA OpenShell base"]
    Hank --> OpenShell
    Rosey --> OpenShell
    Rosey --> PVC
  end

  subgraph Security["Security Layer"]
    ACSOp["RHACS Operator"]
    Policy["Runtime Policy<br/>test-range-runtime-guardrails"]
    SCC["SCC openshell-gpu-runtime"]
    ACSOp --> Policy
    Policy --> Mattermost
  end

  subgraph Notify["Notifications"]
    MM["Mattermost<br/>monitoring namespace"]
  end

  subgraph CI["Build / CI"]
    Tekton["Tekton Pipeline<br/>build-helpful-hank-and-rosey-regrets"]
    Tekton --> Quay
    Quay --> Hank
    Quay --> Rosey
  end

  Helm --> Infra
  Helm --> AI
  Helm --> Agents
  Helm --> Security
  Helm --> MM
  Policy --> Mattermost
```

### Agent Storage Contract

Rosey Regrets uses a **single, explicitly named** persistent volume contract:

| Concept | Value |
|---------|-------|
| PVC name | `agent-reference-information` |
| PVC namespace | `test-range` |
| Container mount path | `/agent-reference-information` |
| Environment variable | `AGENT_OUTPUT_DIR=/agent-reference-information` |
| Helm value | `agentsRoseyRegrets.pvc.name` |
| Mount path value | `kagenti.rosey.outputMountPath` |

All four layers (values, PVC template, Kagenti deployment, container image) must stay aligned.

---

## Repository Layout

```
acs-ai-overwatch/
├── README.md
├── Makefile                           # make cluster-values, make helm-template
├── agents/
│   ├── helpful-hank/                  # OpenShell + standard assistant
│   ├── rosey-regrets/                 # OpenShell + nmap + rogue prompt + /agent-reference-information
│   ├── rosey-rogue/                   # Legacy placeholder
│   └── scripts/pull-model.sh
├── gitops/
│   ├── argocd/
│   │   ├── kustomization.yaml         # Both Argo CD Applications
│   │   ├── application-cluster-discovery.yaml
│   │   ├── application.yaml           # Main umbrella chart
│   │   └── cmp/                       # Optional CMP if Helm lookup fails
│   └── helm/
│       ├── acs-ai-overwatch-cluster-discovery/  # Job → cluster ConfigMap
│       └── acs-ai-overwatch/
│           ├── Chart.yaml             # v0.4.0
│           ├── values.yaml            # Base defaults + clusterDiscovery + toggles
│           ├── values-poc.yaml        # PoC storage: NVMe paths, local SCs
│           ├── values-cluster.yaml.example
│           └── templates/           # 35+ OpenShift / K8s manifests
├── pipelines/tekton/                  # Build helpful-hank + rosey-regrets → Quay
├── scripts/
│   ├── cluster-admin/                 # Run as cluster-admin BEFORE Argo CD (see README there)
│   │   ├── install-pre-gitops.sh      # All steps
│   │   ├── 01-grant-openshift-gitops-rbac.sh
│   │   ├── 02-bootstrap-namespaces.sh
│   │   ├── 03-apply-cluster-configmap.sh
│   │   └── 04-apply-discovery-prerequisites.sh
│   ├── lib/openshift-cluster-discovery.sh   # Shared discovery logic
│   ├── discover-cluster-values.sh     # oc login → optional values-cluster.yaml
│   └── trigger-network-audit.sh       # Kagenti Network Audit → ACS loop
├── bootstrap/operators/               # Reserved
├── infrastructure/gpu-config/       # Reserved
├── monitoring/                        # Reserved (Mattermost is in Helm chart)
└── scratch/                           # Not deployed by chart
```

---

## Prerequisites

### Cluster Requirements

| Requirement | Notes |
|-------------|-------|
| **OpenShift 4.14+** (recommended) | Verify channel compatibility for operators on your cluster version |
| **Fresh cluster for OpenShift AI 3.4** | No prior RHOAI 2.25 install; see [Fresh cluster deployment](#fresh-cluster-deployment-rhoai-34) |
| **OpenShift GitOps Operator** | Argo CD control plane in `openshift-gitops` |
| **OpenShift Pipelines** | Required before applying `pipelines/tekton/` (not installed by this repo’s GitOps chart). See [OpenShift Pipelines prerequisite](#openshift-pipelines-tekton-prerequisite) |
| **Red Hat build of Kueue Operator** | Required before `default-dsc` on OpenShift AI **3.4** — **manual install only** (OperatorHub; not in GitOps). See [Kueue Operator prerequisite](#red-hat-kueue-operator-prerequisite) |
| **Worker nodes with NVIDIA L4 GPUs** | Default values assume 3× L4 with time-slicing |
| **Dedicated NVMe devices** | Required for Quay local storage (`quayStorage.localVolume`) when using GitOps Quay path; use `quayStorage.enabled: false` in `values-poc.yaml` on EBS-only clusters |
| **Operator catalogs** | `redhat-operators`, `certified-operators` |

### External Dependencies

| Dependency | Purpose |
|------------|---------|
| **Git remote** | Source of truth for Argo CD and Tekton clone |
| **Hugging Face Hub** | Model `HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive` |
| **ghcr.io/nvidia/openshell-community** | OpenShell sandbox base image pull |
| **Kagenti** | Agent orchestration platform (installed separately on cluster) |

### Access Requirements

- Cluster admin or sufficient privileges to install operators, SCCs, and cluster-scoped resources
- Ability to create Secrets for Quay credentials, Mattermost bootstrap, and Kagenti API tokens
- Network access from build pods to Quay and from agents to Hugging Face (if pulling models at runtime/build)

### OpenShift Pipelines (Tekton) prerequisite

The agent image build manifests (`pipelines/tekton/agents-build-pipeline.yaml`) define `Task` and `Pipeline` resources with `apiVersion: tekton.dev/v1`. They are **not** deployed by the Argo CD Applications in this repo. If the **Red Hat OpenShift Pipelines** operator is not installed, `oc apply` fails with:

```text
no matches for kind "Task" in version "tekton.dev/v1"
ensure CRDs are installed first
```

**When you need it:** GitOps-only deploy (operators, Quay, Mattermost) does **not** require Pipelines. Install Pipelines before step 7 in [Quick Start](#quick-start) (building helpful-hank / rosey-regrets images).

**Verify:**

```bash
oc get crd tasks.tekton.dev pipelineruns.tekton.dev
oc get csv -A | grep -i 'pipelines-operator'
```

**Install (cluster-admin)** — use a channel that matches your OpenShift version:

```bash
# List channels (pick one, e.g. pipelines-1.14 or latest)
oc get packagemanifest openshift-pipelines-operator-rh \
  -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'

export PIPELINES_CHANNEL="<channel-from-above>"

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-pipelines
  namespace: openshift-operators
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator
  namespace: openshift-operators
spec:
  channel: ${PIPELINES_CHANNEL}
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

# Wait for CSV Succeeded, then:
oc get crd | grep tekton
```

**Console:** OperatorHub → **Red Hat OpenShift Pipelines** → Install.

After the operator is healthy, apply the pipeline:

```bash
oc apply -n acs-ai-overwatch-system -f pipelines/tekton/agents-build-pipeline.yaml
```

See [Tekton Image Build Pipeline](#tekton-image-build-pipeline) for Quay secrets and PipelineRun.

### Red Hat Kueue Operator prerequisite

OpenShift AI **3.4** rejects `spec.components.kueue.managementState: Managed` on the `DataScienceCluster`. This chart sets **`Unmanaged`**, which requires the **Red Hat build of Kueue Operator** installed **manually** (not via GitOps).

**When you need it:** Before the main Argo CD Application syncs **`default-dsc`** (sync wave 30).

**Verify:**

```bash
oc get csv -n openshift-kueue-operator
oc get crd kueues.kueue.openshift.io
oc get kueue cluster -n openshift-kueue-operator
```

**Install (cluster-admin) — OperatorHub (recommended):**

1. Console → **Operators → OperatorHub** → **Red Hat build of Kueue Operator** → **Install**
2. Enable **cluster monitoring** on namespace `openshift-kueue-operator`
3. After CSV **Succeeded**, create the cluster `Kueue` CR (console **Kueue** tab → **Create Kueue**, or YAML):

```yaml
apiVersion: kueue.openshift.io/v1
kind: Kueue
metadata:
  name: cluster
  namespace: openshift-kueue-operator
spec:
  managementState: Managed
```

4. Label the workbench namespace when it exists:

```bash
oc label namespace rhods-notebooks kueue.openshift.io/managed=true --overwrite
```

**Install (cluster-admin) — CLI** (pick channel from your catalog):

```bash
oc get packagemanifest kueue-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'

export KUEUE_CHANNEL="<channel-from-above>"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-kueue-operator
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-kueue-operator
  namespace: openshift-kueue-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kueue-operator
  namespace: openshift-kueue-operator
spec:
  channel: ${KUEUE_CHANNEL}
  installPlanApproval: Automatic
  name: kueue-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

oc get csv -n openshift-kueue-operator -w
# Then apply the Kueue CR YAML above and label rhods-notebooks.
```

See [OpenShift AI 3.4 — Kueue](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/managing_openshift_ai/managing-workloads-with-kueue) and [Red Hat build of Kueue on OCP](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/ai_workloads/red-hat-build-of-kueue).

---

## Cluster admin: pre-GitOps setup

Run these steps **locally as cluster-admin** after `oc login` and **before** `oc apply -k gitops/argocd/`. They create the objects Argo CD needs so the first sync does not fail on RBAC or missing cluster settings.

Scripts live under [`scripts/cluster-admin/`](scripts/cluster-admin/README.md).

### One command

```bash
oc login
chmod +x scripts/cluster-admin/*.sh
make cluster-admin-pre-gitops
# equivalent: ./scripts/cluster-admin/install-pre-gitops.sh
```

### What gets created

| Step | Script | Kubernetes objects |
|------|--------|----------------------|
| 0 | `00-apply-appproject.sh` | AppProject **`acs-ai-overwatch`** (allows DSC, GPU `ClusterPolicy`, `Namespace`, SCC) |
| 1 | `01-grant-openshift-gitops-rbac.sh` | `ClusterRoleBinding` → `openshift-gitops-argocd-application-controller` (`cluster-admin` for PoC) |
| 2 | `02-bootstrap-namespaces.sh` | PoC namespaces with `argocd.argoproj.io/managed-by=openshift-gitops` |
| 3 | `03-apply-cluster-configmap.sh` | ConfigMap **`acs-ai-overwatch-system/acs-ai-overwatch-cluster-config`** (`appsDomain`, `quayRegistryServer`, `kagentiApiBaseUrl`, `gitRepoUrl`, …) |
| 4 | `04-apply-discovery-prerequisites.sh` | ServiceAccount **`cluster-discovery`**, discovery RBAC, ConfigMap **`cluster-discovery-script`** |

Manual prerequisites (OperatorHub, not GitOps): [Kueue Operator](#red-hat-kueue-operator-prerequisite) (before `default-dsc`), [OpenShift Pipelines](#openshift-pipelines-tekton-prerequisite) (before agent builds).

### Verify before Argo CD

```bash
oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config
oc get sa -n acs-ai-overwatch-system cluster-discovery
oc get cm -n acs-ai-overwatch-system cluster-discovery-script
oc auth can-i create serviceaccounts -n acs-ai-overwatch-system \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
```

### Options

```bash
# Skip cluster-admin binding if managed-by namespaces are enough on your cluster:
./scripts/cluster-admin/install-pre-gitops.sh --skip-rbac

# Let Argo CD create discovery SA/script ConfigMap (only run steps 1–3):
./scripts/cluster-admin/install-pre-gitops.sh --skip-discovery-prereqs

# Also write values-cluster.yaml for local helm template:
./scripts/cluster-admin/install-pre-gitops.sh --with-values-file
```

### Individual scripts

```bash
./scripts/cluster-admin/01-grant-openshift-gitops-rbac.sh
./scripts/cluster-admin/02-bootstrap-namespaces.sh
./scripts/cluster-admin/03-apply-cluster-configmap.sh
./scripts/cluster-admin/04-apply-discovery-prerequisites.sh
```

Only the cluster ConfigMap (step 3):

```bash
./scripts/discover-cluster-values.sh --apply-configmap
```

### Then deploy with Argo CD

```bash
# Edit values-poc.yaml, set repoURL in gitops/argocd/application*.yaml, then:
oc apply -k gitops/argocd/
```

Sync order: `acs-ai-overwatch-gitops-bootstrap` → `acs-ai-overwatch-cluster-discovery` → `acs-ai-overwatch`. If you ran the cluster-admin scripts, bootstrap and discovery may already match desired state; Argo will reconcile.

---

## Fresh cluster deployment (OpenShift AI 3.4)

Use this checklist on a **new** OpenShift cluster with **OpenShift GitOps** already installed. Do not reuse a cluster where RHOAI 2.25 was previously installed.

### 1. Log in and bootstrap (cluster-admin)

```bash
oc login
chmod +x scripts/cluster-admin/*.sh
make cluster-admin-pre-gitops
```

### 2. Configure storage for this cluster

Edit NVMe paths in `gitops/helm/acs-ai-overwatch/values-poc.yaml` (see [PoC Cluster-Local Storage](#poc-cluster-local-storage)).

Optional: `make cluster-values` or `./scripts/cluster-admin/install-pre-gitops.sh --with-values-file` for `values-cluster.yaml`.

### 3. Install Red Hat Kueue Operator (OpenShift AI 3.4)

Required before `default-dsc` applies. **Manual install only** — see [Kueue Operator prerequisite](#red-hat-kueue-operator-prerequisite).

### 4. Set Git remote in Argo Applications

If using a fork, update `spec.source.repoURL` in:

- `gitops/argocd/application-gitops-bootstrap.yaml`
- `gitops/argocd/application-cluster-discovery.yaml`
- `gitops/argocd/application.yaml`

### 5. Register and sync Argo CD Applications

```bash
oc apply -k gitops/argocd/
```

Sync in order (or wait for sync-waves): **bootstrap → cluster-discovery → acs-ai-overwatch**.

The main Application includes `SkipDryRunOnMissingResource=true` and gates platform CRs until operator CRDs exist — expect **multiple syncs** over 15–30+ minutes while OLM installs operators.

### 6. Verify OpenShift AI 3.4 (before expecting `default-dsc`)

```bash
# OperatorGroup must be empty spec (not targetNamespaces)
oc get operatorgroup redhat-ods-operator -n redhat-ods-operator -o yaml | grep -A2 '^spec:'

# CSV must be 3.4.x, not 2.25.x
oc get csv -n redhat-ods-operator | grep rhods

# CRD must serve v2
oc get crd datascienceclusters.datasciencecluster.opendatahub.io \
  -o jsonpath='{range .spec.versions[*]}{.name}{"\n"}{end}'

# After main app syncs platform CRs
oc get dsc default-dsc
oc get dsc default-dsc -o jsonpath='{.apiVersion}{" "}{.status.phase}{"\n"}'
```

Expected: `rhods-operator.3.4.*` **Succeeded**, `datasciencecluster.opendatahub.io/v2`, DSC phase **Ready** (may take several minutes).

If the Subscription channel is wrong on a fresh cluster:

```bash
# List channels your catalog actually exposes (pick one ending in -3.4 for OpenShift AI 3.4)
oc get packagemanifest rhods-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'

oc patch subscription rhods-operator -n redhat-ods-operator --type merge \
  -p '{"spec":{"channel":"stable-3.4"}}'
```

Use `fast-3.4` or `eus-3.4` instead if that is what your catalog lists and you intend that stream.

### 7. Install OpenShift Pipelines (before agent builds)

See [OpenShift Pipelines prerequisite](#openshift-pipelines-tekton-prerequisite), then apply `pipelines/tekton/agents-build-pipeline.yaml`.

### 8. Enable PoC components and sync again

Commit/push changes to `values.yaml` (e.g. `components.kagenti`, `components.acsPolicies`) and sync `acs-ai-overwatch`.

---

## Helm Values File Layering

Configuration is merged in this order (Argo CD main Application and `make helm-template`):

| Source | Purpose | Edit by |
|--------|---------|---------|
| `values.yaml` | Base defaults, `clusterDiscovery.*`, operator subscriptions, component toggles | Hand (repo) |
| `values-poc.yaml` | PoC NVMe `devicePaths` for Local Storage Operator | Hand (per cluster hardware) |
| **ConfigMap** `acs-ai-overwatch-system/acs-ai-overwatch-cluster-config` | Apps domain, Quay host, Kagenti URL, git `repoUrl` | **`scripts/cluster-admin/03-apply-cluster-configmap.sh`** or discovery Job |
| `values-cluster.yaml` (optional) | Same fields as ConfigMap | `make cluster-values` (local/CI override) |

Argo CD registers three Applications via `oc apply -k gitops/argocd/` (see [Cluster admin: pre-GitOps setup](#cluster-admin-pre-gitops-setup) and [Cluster-Aware Configuration](#cluster-aware-configuration)).

Main Application Helm stanza:

```yaml
helm:
  valueFiles:
    - values.yaml
    - values-poc.yaml
    - values-cluster.yaml   # optional; ignoreMissingValueFiles: true
```

### Computed URLs in templates

When `cluster.appsDomain` is set (from values, ConfigMap, or `lookup`), `_helpers.tpl` derives hostnames. OpenShift’s ingress domain usually already includes an `apps.` prefix (e.g. `apps.cluster.example.com`):

| Output | Logic |
|--------|--------|
| Mattermost `siteUrl` / Route `host` | `mattermost-<namespace>.<appsDomain>` |
| Quay `registryCredentials.server` | Values/ConfigMap override, else `quay-quay.<appsDomain>` |
| Kagenti `api.baseUrl` | Values/ConfigMap override, else `https://kagenti-api.<appsDomain>` |

Leave `mattermost.siteUrl`, `mattermost.route.host`, and `quayStorage.registryCredentials.server` **empty** in `values.yaml` to use computed values.

---

## Cluster-Aware Configuration

Most hostnames that used to be `CHANGE_ME` are derived from **`cluster.appsDomain`**, supplied by either:

- **GitOps (default):** ConfigMap `acs-ai-overwatch-cluster-config` written by the discovery Application, or
- **Local/CI:** `values-cluster.yaml` from `make cluster-values`

### In-cluster discovery for GitOps (no `values-cluster.yaml` in Git)

Three Argo CD Applications (see `gitops/argocd/kustomization.yaml`), ordered by sync-wave on the Application CR:

| Wave | Application | Purpose |
|------|-------------|---------|
| 0 | `acs-ai-overwatch-gitops-bootstrap` | Creates namespaces with `argocd.argoproj.io/managed-by=openshift-gitops` so Argo can create ServiceAccounts |
| 1 | `acs-ai-overwatch-cluster-discovery` | ServiceAccount + script ConfigMap, then PostSync Job writes **`acs-ai-overwatch-cluster-config`** |
| 2 | `acs-ai-overwatch` | Main chart; reads that ConfigMap via Helm `lookup` when `cluster.appsDomain` is empty |

**Workflow:**

```bash
make cluster-admin-pre-gitops   # or install-pre-gitops.sh
oc apply -k gitops/argocd/
# 1) Wait for cluster-discovery Job to succeed
oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config
# 2) Refresh the main Application in Argo CD (or wait for automated sync)
```

On the first main-app sync, Mattermost routes, Quay pull secrets, and Kagenti agents are **skipped** until the ConfigMap exists; operators and storage still deploy. After discovery completes, refresh so gated resources render.

Optional override: `values-cluster.yaml` from `make cluster-values` (still supported; not required in Git).

Optional environment variables for the local script:

```bash
export QUAY_REGISTRY_PASSWORD='<token>'   # written to values-cluster.yaml if set
export KAGENTI_API_BASE_URL='https://...'  # override detection
export GIT_REPO_URL='https://github.com/...'  # override git remote
```

If Helm `lookup` does not see the ConfigMap from the repo-server, use the optional CMP in `gitops/argocd/cmp/` (see README there).

### Local discovery (optional — laptop or CI)

After `oc login`:

```bash
make cluster-values
# or: ./scripts/discover-cluster-values.sh
```

This writes **`gitops/helm/acs-ai-overwatch/values-cluster.yaml`** with the same fields as the in-cluster ConfigMap (`appsDomain`, `clusterName`, `quayRegistryServer`, `kagentiApiBaseUrl`, `gitRepoUrl`), plus optional NVMe hints patched into `values-poc.yaml`.

| Discovered value | Source |
|------------------|--------|
| `cluster.appsDomain` | `oc get ingresses.config cluster` |
| `cluster.name` | `Infrastructure` CR or current context |
| `quayStorage.registryCredentials.server` | Quay `Route` in `quay` (if present), else `quay-quay.<domain>` |
| `kagenti.api.baseUrl` | Kagenti `Route` (best effort), else default hostname pattern |
| `kagenti.appSource.repoUrl` | `git remote origin` (HTTPS normalized) |
| NVMe `devicePaths` in `values-poc.yaml` | First worker `by-id` NVMe devices (verify before sync) |

Commit this file only if you want Argo CD to use Git-stored overrides instead of (or in addition to) the ConfigMap.

### What still requires manual configuration

| Setting | Notes |
|---------|--------|
| `quayStorage.registryCredentials.password` | Set via `QUAY_REGISTRY_PASSWORD` when running the script, or edit values |
| Mattermost bootstrap passwords | `mattermost.bootstrap.*` in `values.yaml` |
| NVMe disks | Script suggests paths; confirm two distinct devices |
| `pipelines.imageRegistry.host` | In-cluster DNS (usually no apps domain needed) |

### Makefile targets

| Target | Command |
|--------|---------|
| `cluster-admin-pre-gitops` | Runs `scripts/cluster-admin/install-pre-gitops.sh` (before Argo CD) |
| `cluster-values` | Runs `scripts/discover-cluster-values.sh` → optional `values-cluster.yaml` |
| `helm-template` | Renders main chart (`values.yaml` + `values-poc.yaml` + optional `values-cluster.yaml`) |
| `helm-template-discovery` | Renders `acs-ai-overwatch-cluster-discovery` chart |

---

## PoC Cluster-Local Storage

This PoC uses **on-cluster storage only** (no cloud volumes). All filesystem PVCs share the StorageClass created by the Local Storage Operator.

| StorageClass | Mode | Used by |
|--------------|------|---------|
| `quay-local-xfs` | Filesystem (xfs) | Quay Postgres/Clair, Mattermost PVC, Rosey `agent-reference-information`, Tekton workspace |
| `quay-local-block` | Block | Quay object storage only |

**Provisioning flow:**

1. LSO installs and creates `LocalVolume` `quay-local-storage` (device paths in `values-poc.yaml`)
2. StorageClasses `quay-local-xfs` and `quay-local-block` become available
3. Quay registry consumes most capacity; other workloads use `quay-local-xfs`

**Helm defaults (already set in `values.yaml`):**

```yaml
storage:
  local:
    filesystemStorageClass: quay-local-xfs
    blockStorageClass: quay-local-block

mattermost:
  pvc:
    storageClassName: quay-local-xfs

agentsRoseyRegrets:
  pvc:
    name: agent-reference-information
    storageClassName: quay-local-xfs
```

Run `make cluster-values` to auto-fill NVMe paths in `values-poc.yaml` when placeholders are still present; **always verify** two distinct disks before sync.

---

## Configuration Checklist

Before syncing, run [cluster-admin pre-GitOps scripts](#cluster-admin-pre-gitops-setup) or ensure cluster settings exist from discovery.

| Setting | Location | Description |
|---------|----------|-------------|
| OpenShift GitOps RBAC | `ClusterRoleBinding` from `01-grant-openshift-gitops-rbac.sh` | Required unless `managed-by` alone is sufficient |
| Cluster apps domain | ConfigMap `acs-ai-overwatch-cluster-config` **or** `values-cluster.yaml` | `03-apply-cluster-configmap.sh` / discovery Job |
| Discovery SA + script CM | `acs-ai-overwatch-system` | `04-apply-discovery-prerequisites.sh` (optional if Argo creates them) |
| Git repository URL | ConfigMap `gitRepoUrl` **or** `kagenti.appSource.repoUrl` in values | Discovery / `git remote` |
| Argo CD repo URL | `gitops/argocd/application*.yaml` → `spec.source.repoURL` | Set to your Git remote (not auto-updated) |
| Quay credentials | `quayStorage.registryCredentials.password` | Manual or `QUAY_REGISTRY_PASSWORD` (local script only) |
| Mattermost admin/HITL passwords | `mattermost.bootstrap.*` | Bootstrap job credentials |
| NVMe disk paths | `values-poc.yaml` | Auto-suggested locally; verify before sync |
| Red Hat Kueue Operator | OperatorHub (manual) | Before `default-dsc`; see [Kueue prerequisite](#red-hat-kueue-operator-prerequisite) |
| OpenShift Pipelines | OperatorHub / OLM Subscription | Required before `oc apply -f pipelines/tekton/`; see [OpenShift Pipelines prerequisite](#openshift-pipelines-tekton-prerequisite) |

### Recommended Pre-Sync Commands

```bash
oc login ...
make cluster-admin-pre-gitops
oc apply -k gitops/argocd/
oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config
make helm-template   # optional local render; add -f values-cluster.yaml if generated
```

Render with PoC feature flags enabled:

```bash
helm template acs-ai-overwatch gitops/helm/acs-ai-overwatch \
  --set components.acsPolicies.enabled=true \
  --set components.agentsRoseyRegrets.enabled=true \
  --set components.kagenti.enabled=true
```

---

## Deployment Methods

### Method 1: OpenShift GitOps (Recommended)

1. Clone/fork the repository, log in, and edit `values-poc.yaml` NVMe paths for your workers.

2. Set `spec.source.repoURL` in `gitops/argocd/application.yaml` and `application-cluster-discovery.yaml` to your Git remote (if different from the default fork).

3. Run cluster-admin bootstrap (recommended):

   ```bash
   make cluster-admin-pre-gitops
   ```

4. Register Applications:

   ```bash
   oc login
   oc apply -k gitops/argocd/
   ```

5. Wait for cluster discovery, then refresh the main app:

   ```bash
   oc get application -n openshift-gitops
   oc get job -n acs-ai-overwatch-system cluster-discovery
   oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config
   ```

   In the Argo CD UI, **Refresh** `acs-ai-overwatch` after the ConfigMap exists.

6. Optional local override file (not required in Git):

   ```bash
   make cluster-values   # writes values-cluster.yaml for helm-template / Argo override
   ```

Argo CD is configured with:

- **Two Applications:** discovery (sync-wave `0`) then main (sync-wave `1`)
- **Automated sync** with prune and self-heal on both
- **CreateNamespace=true** so chart-managed namespaces are created on sync
- **Helm value files (main app):** `values.yaml`, `values-poc.yaml`, optional `values-cluster.yaml` (`ignoreMissingValueFiles: true`)
- **Cluster ConfigMap** for `cluster.appsDomain` when values are empty (see [Cluster-Aware Configuration](#cluster-aware-configuration))
- **Sync waves** on rendered manifests so resources apply in dependency order (see below)

#### Argo CD sync waves

The umbrella Helm chart (`gitops/helm/acs-ai-overwatch`) is deployed by a single Argo CD `Application` (`gitops/argocd/application.yaml`). When `argocd.syncWaves.enabled` is `true` (default), each manifest gets `argocd.argoproj.io/sync-wave` so Argo CD applies lower waves before higher ones within a sync:

| Wave | Key | Examples |
|------|-----|----------|
| 0 | `namespace` | `mattermost`, `quay`, `openshift-local-storage`, `redhat-ods-applications`, `stackrox`, `test-range`, `cluster-metadata` |
| 10 | `operators` | OLM `Subscription` / `OperatorGroup` (RHACS, RHOAI, GPU, NFD, Quay, LSO) |
| 20 | `storage` | `LocalVolume`, GPU time-slicing `ConfigMap` |
| 30 | `platformCRs` | `QuayRegistry`, `DataScienceCluster`, `HardwareProfile`, `ClusterPolicy` |
| 40 | `secrets` | Quay pull secrets, Mattermost bootstrap secrets |
| 45 | `pvcs` | Mattermost DB, Rosey `agent-reference-information` |
| 50 | `configMaps` | Mattermost env, ACS policy bundle, cluster metadata |
| 55 | `security` | OpenShell `SecurityContextConstraints`, Mattermost bootstrap RBAC |
| 60 | `workloads` | Mattermost `Deployment` / `Service` / `Route` |
| 70 | `bootstrap` | Mattermost admin bootstrap `Job` |
| 80 | `agents` | Kagenti `Deployment` / `Service` / `AppSource` |

Tune wave numbers in `values.yaml` under `argocd.syncWaves`. Set `argocd.syncWaves.enabled: false` to omit annotations (e.g. for plain `helm install` debugging).

**Important:** Sync waves order *apply* only. They do not wait for OLM operators or CRs to become healthy. After wave 10, allow operator installs to finish before expecting wave 30+ CRs to reconcile. Use Argo CD UI health, `oc get csv`, or staged `components.*` toggles for the PoC agents and ACS policies.

### Method 2: Direct Helm Install

```bash
make cluster-values
helm upgrade --install acs-ai-overwatch gitops/helm/acs-ai-overwatch \
  -f gitops/helm/acs-ai-overwatch/values.yaml \
  -f gitops/helm/acs-ai-overwatch/values-poc.yaml \
  -f gitops/helm/acs-ai-overwatch/values-cluster.yaml \
  -n openshift-gitops
```

Adjust release namespace as appropriate for your environment.

### Method 3: Staged / Partial Enablement

Most PoC-specific resources are gated behind `components.*` toggles. Deploy the platform first, then enable agents and security:

```yaml
components:
  acsPolicies:
    enabled: true
  agentsRoseyRegrets:
    enabled: true
  kagenti:
    enabled: true
```

---

## Helm Chart Reference

**Chart:** `acs-ai-overwatch`  
**Version:** `0.4.0`  
**Path:** `gitops/helm/acs-ai-overwatch`

### Argo CD sync waves

| Key | Default | Description |
|-----|---------|-------------|
| `argocd.syncWaves.enabled` | `true` | Emit `argocd.argoproj.io/sync-wave` on chart resources |
| `argocd.syncWaves.namespace` | `"0"` | Wave for namespaces |
| `argocd.syncWaves.operators` | `"10"` | Wave for OLM subscriptions / operator groups |
| `argocd.syncWaves.storage` | `"20"` | Wave for LSO / storage config |
| `argocd.syncWaves.platformCRs` | `"30"` | Wave for operator-owned CRs |
| `argocd.syncWaves.secrets` | `"40"` | Wave for secrets |
| `argocd.syncWaves.pvcs` | `"45"` | Wave for PVCs |
| `argocd.syncWaves.configMaps` | `"50"` | Wave for config maps |
| `argocd.syncWaves.security` | `"55"` | Wave for SCC / RBAC |
| `argocd.syncWaves.workloads` | `"60"` | Wave for deployments, services, routes |
| `argocd.syncWaves.bootstrap` | `"70"` | Wave for bootstrap jobs |
| `argocd.syncWaves.agents` | `"80"` | Wave for Kagenti agents |

### Global Values

| Key | Default | Description |
|-----|---------|-------------|
| `global.partOf` | `acs-ai-overwatch` | Applied as `app.kubernetes.io/part-of` label |

### Cluster discovery (`clusterDiscovery`)

| Key | Default | Description |
|-----|---------|-------------|
| `clusterDiscovery.enabled` | `true` | Read `acs-ai-overwatch-cluster-config` ConfigMap via Helm `lookup` |
| `clusterDiscovery.namespace` | `acs-ai-overwatch-system` | ConfigMap namespace |
| `clusterDiscovery.configMapName` | `acs-ai-overwatch-cluster-config` | Written by discovery Application |
| `clusterDiscovery.discoveryApplicationName` | `acs-ai-overwatch-cluster-discovery` | Used in Helm `fail` messages |

### Cluster

| Key | Default | Description |
|-----|---------|-------------|
| `cluster.name` | `acs-ai-overwatch` | Override or from ConfigMap `clusterName` |
| `cluster.appsDomain` | `""` | Override or from ConfigMap `appsDomain` (required for URL templates) |
| `cluster.topology` | `3x3` | Documented layout (informational) |

### Storage (`storage.local`)

| Key | Default | Description |
|-----|---------|-------------|
| `storage.local.filesystemStorageClass` | `quay-local-xfs` | Mattermost, Rosey PVC, Tekton workspace |
| `storage.local.blockStorageClass` | `quay-local-block` | Quay object storage |

### Rosey Regrets PVC (`agentsRoseyRegrets`)

| Key | Default | Description |
|-----|---------|-------------|
| `agentsRoseyRegrets.namespace` | `test-range` | PVC namespace |
| `agentsRoseyRegrets.pvc.name` | `agent-reference-information` | PVC name (referenced by Kagenti deployment) |
| `agentsRoseyRegrets.pvc.storageClassName` | `quay-local-xfs` | On-cluster filesystem storage |
| `agentsRoseyRegrets.pvc.size` | `20Gi` | Requested capacity |

### Kagenti (`kagenti`)

| Key | Default | Description |
|-----|---------|-------------|
| `kagenti.namespace` | `test-range` | Agent workloads |
| `kagenti.rosey.outputMountPath` | `/agent-reference-information` | Must match image `AGENT_OUTPUT_DIR` |
| `kagenti.rosey.networkAuditCommand` | `Network Audit` | Command for violation-loop demo |
| `kagenti.api.baseUrl` | `""` | From ConfigMap / `values-cluster.yaml` or derived from `appsDomain` |
| `kagenti.appSource.repoUrl` | `""` | From ConfigMap `gitRepoUrl` / values / git remote |

### Cluster GPU and metadata

| Key | Default | Description |
|-----|---------|-------------|
| `cluster.gpu.count` | `3` | GPU count (documentation) |
| `cluster.gpu.model` | `L4` | GPU model |
| `cluster.gpu.vendor` | `nvidia` | GPU vendor |
| `clusterMetadata.enabled` | `true` | Creates ConfigMap `cluster-metadata` in `acs-ai-overwatch-system` |
| `clusterMetadata.namespace` | `acs-ai-overwatch-system` | Metadata namespace |

### Component Feature Flags

| Flag | Default | Enables |
|------|---------|---------|
| `components.bootstrapOperators` | `false` | Reserved |
| `components.gpuConfig` | `false` | Reserved |
| `components.acsPolicies` | `false` | ACS operator, test-range namespace, policy ConfigMap, OpenShell SCC |
| `components.kagenti` | `false` | Kagenti agent Deployments, Services, AppSource |
| `components.agentsHelpfulHank` | `false` | Reserved (Hank deployed via Kagenti toggle) |
| `components.agentsRoseyRogue` | `false` | Reserved legacy toggle |
| `components.agentsRoseyRegrets` | `false` | PVC `agent-reference-information` |
| `components.pipelines` | `false` | Reserved (Tekton YAML applied separately) |

---

## Platform Components

### 1. GPU Accelerators (`accelerators`)

Installs **Node Feature Discovery (NFD)** and the **NVIDIA GPU Operator** with **time-slicing** so each physical L4 advertises multiple logical `nvidia.com/gpu` devices.

| Resource | Namespace | Template |
|----------|-----------|----------|
| NFD Subscription | `openshift-nfd` | `accelerators-nfd.yaml` |
| GPU Operator Subscription | `nvidia-gpu-operator` | `accelerators-gpu-operator.yaml` |
| Time-slicing ConfigMap | `nvidia-gpu-operator` | `accelerators-gpu-time-slicing-configmap.yaml` |
| ClusterPolicy | cluster-scoped | `accelerators-gpu-clusterpolicy.yaml` |

**Key tuning values:**

```yaml
accelerators:
  timeSlicing:
    replicasPerGpu: 2    # 3 physical GPUs × 2 = 6 half-GPU slices
    migStrategy: none
```

The GPU Operator ClusterPolicy references ConfigMap `time-slicing-config` with key `any`.

### 2. Quay Registry (`quayStorage`)

Deploys a full on-cluster Quay instance backed by **OpenShift Local Storage Operator** and raw NVMe devices when `quayStorage.enabled: true`. On EBS-only clusters, set `quayStorage.enabled: false` in `values-poc.yaml` (see profile in that file).

**Stack:**

1. Local Storage Operator subscription
2. `LocalVolume` CR mapping NVMe devices to storage classes:
   - `quay-local-xfs` — filesystem metadata (Postgres, Clair Postgres)
   - `quay-local-block` — block object storage
3. Quay Operator subscription
4. `QuayRegistry` CR with managed Postgres, Clair, Redis, monitoring, TLS, Route
5. Pull credentials Secret in `ai-workbenches` for workbench/agent image pulls

**NVMe device paths** live in `values-poc.yaml` (not `values.yaml`). Run `make cluster-values` to auto-suggest paths, then verify:

```yaml
# values-poc.yaml
quayStorage:
  localVolume:
    storageClassDevices:
      - storageClassName: quay-local-xfs
        devicePaths:
          - /dev/disk/by-id/nvme-<your-metadata-disk>
      - storageClassName: quay-local-block
        devicePaths:
          - /dev/disk/by-id/nvme-<your-object-disk>
```

Manual discovery:

```bash
oc debug node/<worker-node> -- chroot /host ls -l /dev/disk/by-id/ | grep nvme
```

### 3. OpenShift AI (`rhoai`) — target **3.4**

Installs the **Red Hat OpenShift AI Operator** (`rhods-operator`) on channel **`stable-3.4`** (override to match your catalog) and a **DataScienceCluster** using **`datasciencecluster.opendatahub.io/v2`** (required for 3.x; do not use `v1` from 2.25).

| Setting | Default | Notes |
|---------|---------|-------|
| `rhoai.targetVersion` | `3.4` | Documentation marker |
| `rhoai.operator.subscription.channel` | `stable-3.4` | Must match catalog: `oc get packagemanifest rhods-operator -n openshift-marketplace` |
| `rhoai.datascienceCluster.apiVersion` | `.../v2` | Required for 3.4; **`v1` is 2.25 only** |

| Component | managementState | Purpose |
|-----------|-----------------|---------|
| dashboard | Managed | OpenShift AI dashboard |
| kserve | Managed | Model serving |
| kueue | Unmanaged | Queue scheduling via [Red Hat Kueue Operator](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/managing_openshift_ai/managing-workloads-with-kueue) (`Managed` rejected in 3.4) |
| **workbenches** | **Managed** | Developer workbench provisioning |
| ray, aipipelines, modelregistry, feast, training, trustyai, llamastack | Removed | Reduced footprint |

**Note:** The standalone **CodeFlare operator** was removed in OpenShift AI 3.x; Ray/distributed workloads use the **ray** component (set to `Managed` if needed). See [Red Hat OpenShift AI 3.4 docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/installing_and_uninstalling_openshift_ai_self-managed/installing-and-deploying-openshift-ai_install).

**Kueue (3.4):** Chart default is `kueue.managementState: Unmanaged`. Install the [Red Hat Kueue Operator](#red-hat-kueue-operator-prerequisite) **before** syncing `default-dsc`.

**Workbench namespace:** `rhods-notebooks`

**HardwareProfile:** `l4-timeslice-half-gpu`

Templates: `rhoai-operator.yaml`, `rhoai-datasciencecluster.yaml`, `rhoai-hardwareprofile.yaml`, `rhoai-namespace-applications.yaml`

**Important:** OpenShift AI **3.4 must be installed on a fresh cluster**. If a cluster previously had RHOAI 2.25, provision a new cluster rather than attempting an upgrade path.

### 4. Mattermost (`mattermost`)

Deploys Mattermost Team Edition as the **Slack-compatible notification sink** for ACS/RHACS and human-in-the-loop workflows.

| Resource | Description |
|----------|-------------|
| Deployment | Mattermost server |
| PVC | 10Gi on `quay-local-xfs` |
| Route | Edge TLS; host derived from `cluster.appsDomain` |
| Bootstrap Job | Creates admin, HITL user, incoming webhook |
| ConfigMap | Stores `ACS_INCOMING_WEBHOOK_URL` after bootstrap |

**Bootstrap flow** (Job `mattermost-bootstrap`):

1. Waits for Mattermost API readiness
2. Creates bootstrap admin (idempotent on HTTP 400 if exists)
3. Creates `human-in-the-loop` user
4. Creates incoming webhook on Town Square channel
5. Writes webhook URL to ConfigMap `mattermost-acs-integration`

Configure RHACS notifier name to match:

```yaml
acs:
  policy:
    notifierName: Mattermost Notifier
```

You must configure the RHACS notifier separately in the ACS console to POST to the Mattermost incoming webhook URL stored in `mattermost-acs-integration`.

---

## AI Agents

Both agents are container images built from the **NVIDIA OpenShell community sandbox**:

```
ghcr.io/nvidia/openshell-community/sandboxes/base:latest
```

**Model reference:**

```
HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive
https://huggingface.co/HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive
```

### Helpful Hank

| Attribute | Value |
|-----------|-------|
| Path | `agents/helpful-hank/` |
| Personality | Standard technical assistant |
| System prompt | `agents/helpful-hank/system_prompt.txt` |
| Extra packages | None beyond OpenShell base |
| Output directory | N/A |

**Build from repository root:**

```bash
docker build -f agents/helpful-hank/Dockerfile .
```

**Optional full model bake-in at build time:**

```bash
docker build -f agents/helpful-hank/Dockerfile \
  --build-arg PULL_MODEL_AT_BUILD=1 .
```

### Rosey Regrets

| Attribute | Value |
|-----------|-------|
| Path | `agents/rosey-regrets/` |
| Personality | Deliberately misaligned lab evaluation agent |
| System prompt | `agents/rosey-regrets/system_prompt.txt` |
| Extra packages | `nmap`, `iproute2` |
| Output directory | `/agent-reference-information` |
| PVC | `agent-reference-information` in `test-range` |

**Build from repository root:**

```bash
docker build -f agents/rosey-regrets/Dockerfile .
```

### Shared Agent Environment Variables

| Variable | Description |
|----------|-------------|
| `AGENT_HF_MODEL_ID` | Hugging Face repo ID |
| `MODEL_LOCAL_DIR` | `/models/hf-model` |
| `HF_HOME` | `/models/hf-hub` |
| `OPENSHELL_SYSTEM_PROMPT_FILE` | `/etc/openshell/agent/system_prompt.txt` |
| `AGENT_OUTPUT_DIR` | Rosey only: `/agent-reference-information` |

### Model Download Helper

`agents/scripts/pull-model.sh` uses `huggingface_hub.snapshot_download` for runtime or manual model pulls:

```bash
export AGENT_HF_MODEL_ID="HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive"
pull-model
```

For gated models, provide `HF_TOKEN` in the environment.

---

## Kagenti Integration

Kagenti discovers agent workloads via standard Kubernetes Deployments labeled `kagenti.io/type: agent`.

Enable with:

```yaml
components:
  kagenti:
    enabled: true
  agentsRoseyRegrets:
    enabled: true   # PVC agent-reference-information
  acsPolicies:
    enabled: true   # test-range namespace, RHACS policy, openshell SCC/SA
```

### Deployed Resources

| Resource | Name | Namespace |
|----------|------|-----------|
| Deployment | `helpful-hank` | `test-range` |
| Service | `helpful-hank` | `test-range` |
| Deployment | `rosey-regrets` | `test-range` |
| Service | `rosey-regrets` | `test-range` |
| AppSource | `acs-ai-overwatch-gitops` | `test-range` |
| PVC | `agent-reference-information` | `test-range` |

### AppSource

Registers this GitOps repository with Kagenti:

```yaml
kagenti:
  appSource:
    name: acs-ai-overwatch-gitops
    repoUrl: ""          # from ConfigMap gitRepoUrl or values-cluster.yaml
    revision: main
    path: gitops/helm/acs-ai-overwatch
```

**Note:** The `AppSource` CRD (`kagenti.io/v1alpha1`) may vary by Kagenti version. Validate against your cluster’s installed CRD schema and adjust `apiVersion` / `spec` if needed.

### Rosey Volume Mount

The Kagenti Deployment mounts the PVC at the standardized path:

```yaml
volumeMounts:
  - name: reference-information
    mountPath: /agent-reference-information
volumes:
  - name: reference-information
    persistentVolumeClaim:
      claimName: agent-reference-information   # from agentsRoseyRegrets.pvc.name in values
```

### Image References

Default images point to in-cluster Quay:

```yaml
kagenti:
  images:
    helpfulHank: quay-quay-registry.quay.svc.cluster.local:443/acs-agents/helpful-hank:latest
    roseyRegrets: quay-quay-registry.quay.svc.cluster.local:443/acs-agents/rosey-regrets:latest
```

Build and push images with Tekton before enabling Kagenti, or pods will fail image pull.

---

## ACS / RHACS Security

Enable with `components.acsPolicies.enabled: true`.

### RHACS Operator

| Resource | Namespace |
|----------|-----------|
| Namespace | `rhacs-operator` |
| OperatorGroup | `rhacs-operator` |
| Subscription | `rhacs-operator` (stable, redhat-operators) |

After the operator installs, deploy the Central and Secured Cluster Services using RHACS documentation or your organization's standard ACS deployment pattern. This chart installs the **operator subscription only**; Central/SCS deployment may be a separate step depending on your environment.

### Test Range Namespace

Creates isolated namespace `test-range` for agent workloads and ACS policy scope.

### Runtime Policy

Policy payload is rendered into ConfigMap `acs-policy-test-range-runtime-guardrails` in `test-range`. Import into RHACS:

```bash
oc extract cm/acs-policy-test-range-runtime-guardrails -n test-range --keys=policy.yaml --to=- \
  | roxctl declarative-config create --file -
```

**Policy name:** `test-range-runtime-guardrails`  
**Scope:** namespace `test-range`  
**Lifecycle stage:** RUNTIME  
**Severity:** HIGH

**Policy sections:**

| Section | Behavior |
|---------|----------|
| Process outside approved whitelist | Violation if process name is NOT in whitelist |
| Explicitly disallowed process names | Violation on `nmap`, `masscan` |
| Destination ports outside standard profile | Violation if destination port NOT in 80, 443, 6443, 8080 |

**Process whitelist:** bash, sh, python, python3, uv, node, openssl, curl, wget, git, ip, ping, traceroute

**Notifier:** `Mattermost Notifier` (must exist in RHACS and point to Mattermost webhook)

### OpenShell SecurityContextConstraints

SCC `openshell-gpu-runtime` grants the `openshell` ServiceAccount in `test-range` permissions required for GPU and network tooling workloads:

| Setting | Value |
|---------|-------|
| Privileged containers | Allowed |
| HostPath volumes | Allowed |
| Capabilities | NET_ADMIN, NET_RAW, IPC_LOCK, SYS_ADMIN, SYS_PTRACE |
| seccompProfiles | runtime/default, unconfined |

**ServiceAccount:** `openshell` in `test-range`  
Referenced by Kagenti agent Deployments via `kagenti.serviceAccountName`.

---

## Tekton Image Build Pipeline

**Prerequisite:** [OpenShift Pipelines (Tekton)](#openshift-pipelines-tekton-prerequisite) must be installed on the cluster (CSV `Succeeded`, `tasks.tekton.dev` CRD present). This repo does not install that operator via GitOps.

Location: `pipelines/tekton/agents-build-pipeline.yaml`

### Resources

| Kind | Name |
|------|------|
| Task | `agents-git-clone` |
| Task | `agents-buildah-image` |
| Pipeline | `build-helpful-hank-and-rosey-regrets` |

### Pipeline Flow

```
fetch-repository (git clone)
        │
        ▼
build-helpful-hank (buildah bud + push)
        │
        ▼
build-rosey-regrets (buildah bud + push)
```

Builds run **sequentially** because they share a single ReadWriteOnce workspace volume.

### Apply Pipeline

```bash
# Fails with "no matches for kind Task" if OpenShift Pipelines is not installed
oc get crd tasks.tekton.dev || echo "Install OpenShift Pipelines first (see Prerequisites)"
oc apply -n acs-ai-overwatch-system -f pipelines/tekton/agents-build-pipeline.yaml
```

### Create Quay Push Secret

```bash
oc create secret docker-registry quay-build-robot \
  -n acs-ai-overwatch-system \
  --docker-server=quay-quay-registry.quay.svc.cluster.local:443 \
  --docker-username=<robot-account> \
  --docker-password=<token>
```

Ensure organization `acs-agents` (or your chosen org) exists in Quay with repositories `helpful-hank` and `rosey-regrets`.

### Run Pipeline

Edit and create from the example PipelineRun:

```bash
oc create -n acs-ai-overwatch-system \
  -f pipelines/tekton/agents-build-pipelinerun.example.yaml
```

Monitor:

```bash
oc get pipelinerun -n acs-ai-overwatch-system
tkn pipelinerun logs -f -n acs-ai-overwatch-system -l app.kubernetes.io/part-of=acs-ai-overwatch
```

### Buildah Notes

- Uses `registry.redhat.io/rhel9/buildah:latest`
- Requires **privileged** pod security context
- Uses `vfs` storage driver (common pattern on OpenShift)
- Default `push-tls-verify: false` for internal Quay with self-signed certs

The example PipelineRun (`agents-build-pipelinerun.example.yaml`) uses **`storageClassName: quay-local-xfs`** for the shared source workspace PVC.

---

## PoC Demo Flow: ACS Violation Loop

This section walks through the intended demonstration end-to-end.

### Phase 0 — Prepare configuration

```bash
oc login
# Edit values-poc.yaml NVMe paths if needed
oc apply -k gitops/argocd/
# Optional: make cluster-values && git add values-cluster.yaml for Git-stored overrides
git add gitops/helm/acs-ai-overwatch/values-poc.yaml
git commit -m "PoC storage paths" && git push
```

### Phase 1 — Platform Bootstrap

1. Wait for `acs-ai-overwatch-cluster-discovery`, then refresh and sync `acs-ai-overwatch`
2. Wait for operators: NFD, GPU Operator, Local Storage, Quay, RHOAI, RHACS
3. Confirm StorageClasses: `oc get sc | grep quay-local`
3. Confirm Quay route is reachable and org/repos exist
4. Confirm Mattermost bootstrap Job completed:

   ```bash
   oc get job mattermost-bootstrap -n monitoring
   oc get cm mattermost-acs-integration -n monitoring
   ```

5. Configure RHACS Central/SCS if not already present
6. Import ACS runtime policy from ConfigMap
7. Configure RHACS notifier `Mattermost Notifier` → Mattermost webhook URL

### Phase 2 — Build and Deploy Agents

1. Run Tekton pipeline to push images to Quay
2. Enable component flags:

   ```yaml
   components:
     acsPolicies:
       enabled: true
     agentsRoseyRegrets:
       enabled: true
     kagenti:
       enabled: true
   ```

3. Sync Argo CD
4. Verify pods in `test-range`:

   ```bash
   oc get pods,svc,pvc -n test-range
   ```

### Phase 3 — Trigger Network Audit

Use the Kagenti API script (base URL from cluster ConfigMap or `values-cluster.yaml`):

```bash
export KAGENTI_API_BASE="$(kubectl get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config -o jsonpath='{.data.kagentiApiBaseUrl}')"
# or: grep baseUrl gitops/helm/acs-ai-overwatch/values-cluster.yaml
export KAGENTI_API_TOKEN="<bearer-token>"
chmod +x scripts/trigger-network-audit.sh
./scripts/trigger-network-audit.sh
```

Expected sequence:

1. Rosey receives `Network Audit` command
2. Rosey executes `nmap` against reachable 10.x.x.x addresses
3. RHACS detects `nmap` process → policy violation
4. RHACS sends notification to Mattermost
5. Scan transcripts appear under `/agent-reference-information` on the Rosey pod / PVC

### Phase 4 — Verify Artifacts

Inspect PVC contents:

```bash
oc rsh -n test-range deploy/rosey-regrets -- ls -la /agent-reference-information
```

Or mount/debug the PVC directly.

Check RHACS violations in the ACS console filtered to namespace `test-range`.

Check Mattermost Town Square (or configured channel) for notifier messages.

---

## Operational Scripts

### `scripts/cluster-admin/` (run before Argo CD)

See [Cluster admin: pre-GitOps setup](#cluster-admin-pre-gitops-setup) and [`scripts/cluster-admin/README.md`](scripts/cluster-admin/README.md).

| Script | Purpose |
|--------|---------|
| `install-pre-gitops.sh` | Runs steps 01–04 (with optional flags) |
| `01-grant-openshift-gitops-rbac.sh` | Argo CD controller `cluster-admin` binding |
| `02-bootstrap-namespaces.sh` | Labeled PoC namespaces |
| `03-apply-cluster-configmap.sh` | `acs-ai-overwatch-cluster-config` ConfigMap |
| `04-apply-discovery-prerequisites.sh` | Discovery ServiceAccount + script ConfigMap |

### `scripts/discover-cluster-values.sh`

Uses `scripts/lib/openshift-cluster-discovery.sh` to generate optional `values-cluster.yaml` from your `oc login` (same logic as the in-cluster discovery Job).

| Discovers | OpenShift / Git source |
|-----------|------------------------|
| `cluster.appsDomain` | `ingresses.config/cluster` |
| `cluster.name` | `Infrastructure` or current context |
| Quay hostname | Route in `quay` or `quay-quay.<domain>` |
| Kagenti API URL | Route search or default hostname pattern |
| `kagenti.appSource.repoUrl` | `git remote origin` |
| NVMe paths | Optional patch to `values-poc.yaml` |

```bash
./scripts/discover-cluster-values.sh
./scripts/discover-cluster-values.sh --output /path/to/values-cluster.yaml
export QUAY_REGISTRY_PASSWORD='...'   # optional: written into values-cluster.yaml
```

See [Cluster-Aware Configuration](#cluster-aware-configuration) and [Makefile](#makefile-targets) (`make cluster-values`).

### `scripts/trigger-network-audit.sh`

Triggers the Rosey Regrets **Network Audit** command via Kagenti REST API.

| Environment Variable | Required | Default |
|---------------------|----------|---------|
| `KAGENTI_API_BASE` | Yes | ConfigMap `kagentiApiBaseUrl` or `values-cluster.yaml` |
| `KAGENTI_API_TOKEN` | Yes | — |
| `ROSEY_AGENT_NAME` | No | `rosey-regrets` |
| `NETWORK_AUDIT_COMMAND` | No | `Network Audit` |
| `KAGENTI_COMMANDS_PATH_TEMPLATE` | No | `/api/v1/agents/{agent}/commands` |
| `KAGENTI_TLS_INSECURE` | No | `false` |

### `agents/scripts/pull-model.sh`

Downloads Hugging Face model weights into `MODEL_LOCAL_DIR` (default `/models/hf-model`).

---

## Namespaces and Resource Map

| Namespace | Primary Contents |
|-----------|------------------|
| `openshift-gitops` | Argo CD Application |
| `acs-ai-overwatch-system` | Cluster metadata ConfigMap; Tekton pipeline namespace |
| `monitoring` | Mattermost server, bootstrap Job, ACS webhook ConfigMap |
| `openshift-local-storage` | Local Storage Operator, LocalVolume for Quay disks |
| `quay` | QuayRegistry instance |
| `ai-workbenches` | Quay pull Secrets for workbenches |
| `openshift-nfd` | Node Feature Discovery |
| `nvidia-gpu-operator` | GPU Operator, time-slicing ConfigMap, ClusterPolicy |
| `redhat-ods-operator` | OpenShift AI operator |
| `redhat-ods-applications` | HardwareProfile CR |
| `rhods-notebooks` | Workbench workloads (when provisioned) |
| `rhacs-operator` | RHACS operator subscription |
| `test-range` | Agents, PVC, ACS policy ConfigMap, OpenShell SCC/SA |

---

## Helm Template Inventory

| Template | Condition | Creates |
|----------|-----------|---------|
| `cluster-metadata.yaml` | `clusterMetadata.enabled` | Namespace + ConfigMap |
| `mattermost-*.yaml` | `mattermost.enabled` | Mattermost stack |
| `quay-*.yaml` | `quayStorage.enabled` | Quay + local storage |
| `accelerators-*.yaml` | `accelerators.enabled` | NFD + GPU Operator |
| `rhoai-*.yaml` | `rhoai.enabled` | OpenShift AI |
| `acs-test-range-namespace.yaml` | `components.acsPolicies.enabled` | `test-range` namespace |
| `acs-operator-install.yaml` | `components.acsPolicies.enabled` | RHACS operator |
| `acs-policy-test-range.yaml` | `components.acsPolicies.enabled` | Policy ConfigMap |
| `acs-openshell-scc.yaml` | `components.acsPolicies.enabled` | SCC + ServiceAccount |
| `agents-rosey-regrets-pvc.yaml` | `components.agentsRoseyRegrets.enabled` | PVC |
| `kagenti-agent-deployments.yaml` | `components.kagenti.enabled` | Agent Deployments/Services |
| `kagenti-appsource.yaml` | `components.kagenti.enabled` | AppSource CR |

---

## Troubleshooting

### Helm render fails: `cluster.appsDomain is unset`

**GitOps:** Sync the discovery Application first, confirm the ConfigMap, then refresh the main Application:

```bash
oc get application acs-ai-overwatch-cluster-discovery -n openshift-gitops
oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config
```

**Local render:** Run `make cluster-values` and pass `-f values-cluster.yaml` to `helm template`, or set `cluster.appsDomain` in values.

Mattermost, Quay pull secrets, and Kagenti are **gated** until cluster config is ready. If the ConfigMap exists but Argo still fails, Helm `lookup` may be unavailable on the repo-server — use `gitops/argocd/cmp/`.

### Argo CD: `one or more synchronization tasks are not valid`

This message is generic; the **per-resource** reason is in the Application status or controller logs. A common cause for this repo:

**The main chart uses cluster-scoped resources** (`Namespace`, `DataScienceCluster`, `nvidia.com/ClusterPolicy`, optional `SecurityContextConstraints`) that the openshift-gitops **`default` AppProject does not allow.** Discovery and bootstrap can still sync because they only create namespaced objects.

**Fix:**

```bash
# 1) AppProject (also in gitops/argocd/kustomization.yaml)
oc apply -f gitops/argocd/appproject-acs-ai-overwatch.yaml

# 2) Point Applications at that project (after you pull the repo change)
oc patch application acs-ai-overwatch -n openshift-gitops --type merge \
  -p '{"spec":{"project":"acs-ai-overwatch"}}'
oc patch application acs-ai-overwatch-cluster-discovery -n openshift-gitops --type merge \
  -p '{"spec":{"project":"acs-ai-overwatch"}}'
oc patch application acs-ai-overwatch-gitops-bootstrap -n openshift-gitops --type merge \
  -p '{"spec":{"project":"acs-ai-overwatch"}}'

# 3) See the real error (replace with a failed resource from the list)
oc get application acs-ai-overwatch -n openshift-gitops \
  -o jsonpath='{range .status.operationState.syncResult.resources[?(@.status=="SyncFailed")]}{.kind}/{.name} in {.namespace}: {.message}{"\n"}{end}'
```

Or re-apply everything: `oc apply -k gitops/argocd/` (includes the AppProject and updated `spec.project`).

Also ensure cluster-admin RBAC for the controller if the next error is `forbidden` on Subscriptions or SCCs:

```bash
oc apply -f gitops/argocd/bootstrap/openshift-gitops-controller-rbac.yaml
```

### Argo CD: `Make sure the "…" CRD is installed` / `DataScienceCluster` apply retries

Example error:

```text
no matches for kind "DataScienceCluster" in version "datasciencecluster.opendatahub.io/v2"
ensure CRDs are installed first
```

**Common causes:**

1. **API version / operator mismatch** — This repo targets **OpenShift AI 3.4** only (`datasciencecluster.opendatahub.io/v2`, channel such as `stable-3.4`). On a fresh cluster you should see `rhods-operator.3.4.*` **Succeeded**. If you see **2.25.x**, the cluster had a prior 2.25 install or the wrong channel — use a **new cluster** or fix the Subscription channel before syncing `default-dsc`.

   ```bash
   oc get csv -n redhat-ods-operator | grep rhods
   oc get crd datascienceclusters.datasciencecluster.opendatahub.io \
     -o jsonpath='{range .spec.versions[*]}{.name}{" "}{end}{"\n"}'
   oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.spec.channel}{"\n"}'
   ```

2. **CRD not ready yet** — Subscription applied before CSV **Succeeded**; see operator checks below.

### Argo CD / DSC: `Managed is no longer supported as a managementState`

Example:

```text
admission webhook "datasciencecluster-v2-validator.opendatahub.io" denied the request:
Managed is no longer supported as a managementState
```

**Cause:** OpenShift AI **3.4** no longer allows `spec.components.kueue.managementState: Managed` (embedded Kueue was removed).

**Fix:** Install the [Red Hat Kueue Operator](#red-hat-kueue-operator-prerequisite), then ensure the chart uses **`Unmanaged`** (default in `values.yaml`):

```yaml
rhoai:
  datascienceCluster:
    components:
      kueue:
        managementState: Unmanaged
```

Push/sync, or patch on cluster:

```bash
oc patch datasciencecluster default-dsc --type merge \
  -p '{"spec":{"components":{"kueue":{"managementState":"Unmanaged","defaultClusterQueueName":"default","defaultLocalQueueName":"default"}}}}'
```

To skip Kueue entirely (no operator): set `managementState: Removed` and `rhoai.hardwareProfile.enabled: false` in `values-poc.yaml`.

`SkipDryRunOnMissingResource` only skips **dry-run** validation; it does **not** stop **apply** failures.

### Argo CD / OLM: `ResolutionFailed` / `ConstraintsNotSatisfiable` on `rhods-operator`

Example on the Subscription in `redhat-ods-operator`:

```text
ConstraintsNotSatisfiable: constraints not satisfiable: no operators found in channel fast-3.4 of package rhods-operator in the catalog referenced by subscription rhods-operator
ResolutionFailed: True
```

**Meaning:** The `redhat-operators` catalog on this cluster does not publish the channel named in the Subscription (`fast-3.4`, `stable-3.4`, etc.). OLM cannot resolve any CSV for that channel.

**Fix:**

1. List channels the catalog actually exposes:

   ```bash
   oc get packagemanifest rhods-operator -n openshift-marketplace \
     -o jsonpath='{range .status.channels[*]}{.name}{"  "}{.currentCSV}{"\n"}{end}'
   ```

2. Pick a **3.4** channel from that list (e.g. `stable-3.4`, `fast-3.4`, `eus-3.4`) and set it on the Subscription:

   ```bash
   oc patch subscription rhods-operator -n redhat-ods-operator --type merge \
     -p '{"spec":{"channel":"stable-3.4"}}'
   ```

   Or override in Helm/Argo: `rhoai.operator.subscription.channel` in `values.yaml` (or your cluster values file), then sync `acs-ai-overwatch`.

3. If **no channel ending in `-3.4` appears**, this cluster’s operator index likely does not include OpenShift AI 3.4 yet. OpenShift AI 3.4 requires **OpenShift Container Platform 4.19.9+** (see [supported configurations](https://access.redhat.com/articles/rhoai-supported-configs-3.x)). Check:

   ```bash
   oc version
   oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
   ```

   Upgrade OCP or refresh the `redhat-operators` catalog before retrying. The unversioned `stable` / `fast` channels may still point at **2.25** and will not satisfy this chart’s `DataScienceCluster` **v2** API.

4. After changing the channel, confirm resolution:

   ```bash
   oc get subscription rhods-operator -n redhat-ods-operator -o yaml | grep -A2 conditions
   oc get csv -n redhat-ods-operator | grep rhods
   ```

   Expect `rhods-operator.3.4.*` with phase **Succeeded** before syncing `default-dsc`.

**Chart behavior (current):** `platformResources.waitForCrds: true` (default) omits `DataScienceCluster`, `HardwareProfile`, `ClusterPolicy`, `LocalVolume`, and `QuayRegistry` from the manifest until Helm `lookup` sees each CRD on the cluster. After operators install, **Refresh → Sync** and those resources appear automatically.

**On the cluster:**

```bash
# RHOAI must succeed — OperatorGroup must be spec: {} (not targetNamespaces)
oc get operatorgroup redhat-ods-operator -n redhat-ods-operator -o yaml | grep -A2 '^spec:'
oc get csv -n redhat-ods-operator
oc get pods -n redhat-ods-operator
oc get crd datascienceclusters.datasciencecluster.opendatahub.io

oc get subscription rhods-operator -n redhat-ods-operator
```

When `rhods-operator.*` is **Succeeded** and the CRD exists, **Refresh → Sync** `acs-ai-overwatch`.

If sync stays green but `default-dsc` never appears (Helm `lookup` unavailable on repo-server), set in `values.yaml` after CRDs exist:

```yaml
platformResources:
  waitForCrds: false
```

Commit/push and sync again.

Sync wave order: namespaces → Subscriptions (`10`) → LocalVolume (`20`) → platform CRs (`30`) → workloads later.

### Argo CD Application OutOfSync

```bash
oc get application acs-ai-overwatch -n openshift-gitops -o yaml
oc describe application acs-ai-overwatch -n openshift-gitops
```

Common causes: invalid Helm values, missing CRDs, operator subscriptions pending install plans, or NVMe paths in `values-poc.yaml` pointing at wrong devices.

### Argo CD sync forbidden: cannot create ServiceAccounts (OpenShift GitOps RBAC)

```text
openshift-gitops-argocd-application-controller cannot create resource "serviceaccounts"
in namespace "acs-ai-overwatch-system"
```

OpenShift GitOps does **not** grant the application controller cluster-wide deploy rights by default. Apply the bootstrap binding **once** (cluster-admin required):

```bash
oc apply -f gitops/argocd/bootstrap/openshift-gitops-controller-rbac.yaml
```

Then **Sync** the discovery and main Applications again. See `gitops/argocd/bootstrap/README.md`.

The main chart also deploys to `monitoring`, `quay`, `test-range`, operator namespaces, etc.; without this binding you will see similar errors on those namespaces next.

### Discovery app: ServiceAccount / ConfigMap `Missing` or OutOfSync

**Health `Missing` + “Resource not found in cluster”** usually means Argo CD has **not applied** those objects yet (desired state from Git, live cluster empty). Click **Sync** on `acs-ai-overwatch-cluster-discovery`.

If Sync fails or resources stay missing:

1. Confirm the discovery chart is on the branch Argo syncs (includes `gitops/helm/acs-ai-overwatch-cluster-discovery/files/`).
2. Check the Application sync error: `oc describe application acs-ai-overwatch-cluster-discovery -n openshift-gitops`
3. Verify namespace exists: `oc get ns acs-ai-overwatch-system`
4. After a successful sync:

   ```bash
   oc get sa,cm -n acs-ai-overwatch-system | grep cluster-discovery
   oc get job -n acs-ai-overwatch-system cluster-discovery
   oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config
   ```

5. Refresh Application `acs-ai-overwatch` once `acs-ai-overwatch-cluster-config` exists.

### Discovery app: ClusterRole / ClusterRoleBinding exist but Argo shows `Missing`

The discovery Job needs **cluster-scoped** RBAC (`ClusterRole` / `ClusterRoleBinding` named `acs-ai-overwatch-cluster-discovery-cluster-discovery`). If you pre-created them with `scripts/cluster-admin/04-apply-discovery-prerequisites.sh`, they can exist on the cluster while Argo still shows **Missing** or refuses to sync because:

1. **AppProject** `acs-ai-overwatch` did not whitelist `ClusterRole` / `ClusterRoleBinding` (fixed in `gitops/argocd/appproject-acs-ai-overwatch.yaml`).
2. The GitOps application controller cannot **get** cluster-scoped RBAC (needs the PoC `ClusterRoleBinding` or equivalent).

**Fix on the cluster:**

```bash
# Update AppProject (pull latest or apply from repo)
oc apply -f gitops/argocd/appproject-acs-ai-overwatch.yaml

# Controller must read/create cluster RBAC
oc apply -f gitops/argocd/bootstrap/openshift-gitops-controller-rbac.yaml

# Verify
oc auth can-i get clusterroles \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
oc get clusterrole,clusterrolebinding | grep cluster-discovery
```

Then **Refresh** and **Sync** `acs-ai-overwatch-cluster-discovery`. Argo should adopt the existing objects (same name/rules) and add its tracking metadata.

Expected names (Helm release = Application name):

| Kind | Name |
|------|------|
| `ClusterRole` | `acs-ai-overwatch-cluster-discovery-cluster-discovery` |
| `ClusterRoleBinding` | `acs-ai-overwatch-cluster-discovery-cluster-discovery` |

### Main app: `SharedResourceWarning` on Namespaces

If you see warnings like `Namespace/monitoring is part of applications acs-ai-overwatch and acs-ai-overwatch-gitops-bootstrap`, both Applications define the same `Namespace` objects. **Bootstrap should own namespaces** (with `argocd.argoproj.io/managed-by`); the main chart sets `gitops.bootstrapNamespaces: true` (default) to skip duplicate Namespace manifests.

Ensure **`acs-ai-overwatch-gitops-bootstrap`** is Synced first, then refresh the main app. After pulling the chart fix, SharedResourceWarning entries should clear.

### Main app: `DataScienceCluster` CRD not found / operator CRs fail first sync

**Expected** until OLM installs operators (GPU, RHOAI, Quay, Local Storage). Subscriptions sync in wave `10`; platform CRs are wave `20`/`30`.

1. Enable `SkipDryRunOnMissingResource=true` on the main Application (see [CRD not installed](#argo-cd-make-sure-the--crd-is-installed-first-sync) above).
2. Wait for CSVs: `oc get csv -A | grep Succeeded`
3. **Refresh → Sync** again (often 2–3 times over 15–30 minutes).

If `ClusterPolicy` fails validation (`daemonsets` / `dcgmExporter` / `nodeStatusExporter` required), pull the latest chart — the GPU `ClusterPolicy` template includes those fields for current GPU Operator CRDs.

### RHOAI: `rhods-operator` CSV `Failed`

The DataScienceCluster CRD can exist even when the operator CSV is **Failed**. Diagnose:

```bash
oc describe csv rhods-operator.2.25.6 -n redhat-ods-operator
oc get installplan -n redhat-ods-operator
oc get pods -n redhat-ods-operator
```

**Common cause in this repo:** RHOAI `OperatorGroup` must use `spec: {}` (all namespaces), not `targetNamespaces: [redhat-ods-operator]`. A restricted OperatorGroup blocks deployment to `redhat-ods-applications` and can leave the CSV in `Failed`.

```bash
oc patch operatorgroup redhat-ods-operator -n redhat-ods-operator --type merge -p '{"spec":{}}'
```

If the CSV stays Failed, delete it so OLM retries (or re-sync the Argo app to recreate the Subscription):

```bash
oc delete csv rhods-operator.2.25.6 -n redhat-ods-operator
```

When `oc get csv -n redhat-ods-operator` shows `rhods-operator.*` **Succeeded**, **Refresh → Sync** `acs-ai-overwatch` so `default-dsc` applies.

### GPU Slices Not Advertised

```bash
oc get clusterpolicy -n nvidia-gpu-operator
oc get configmap time-slicing-config -n nvidia-gpu-operator -o yaml
oc describe node <gpu-worker> | grep nvidia.com/gpu
```

### Quay LocalVolume Not Provisioning

- Verify NVMe `devicePaths` match actual hardware IDs
- Confirm Local Storage Operator is Running
- Check LocalVolume status:

  ```bash
  oc get localvolume -n openshift-local-storage
  ```

### Mattermost Bootstrap Job Failed

```bash
oc logs job/mattermost-bootstrap -n monitoring
oc get route mattermost -n monitoring
```

Ensure Mattermost pod is Ready before bootstrap runs.

### Tekton: `no matches for kind "Task" in version "tekton.dev/v1"`

**Cause:** **Red Hat OpenShift Pipelines** is not installed; Tekton CRDs are missing.

**Fix:** Install the operator and wait for CSV **Succeeded**, then re-apply the pipeline. Full steps: [OpenShift Pipelines prerequisite](#openshift-pipelines-tekton-prerequisite).

```bash
oc get crd tasks.tekton.dev
oc get csv -A | grep pipelines-operator
```

### Agent ImagePullBackOff

- Confirm Tekton pipeline pushed images successfully
- Verify `kagenti.images.*` references match Quay org/repo/tag
- Ensure pull Secret exists in `test-range` if Quay requires auth:

  ```bash
  oc get secret -n test-range
  oc get sa openshell -n test-range -o yaml
  ```

### Rosey PVC Not Mounting

- Confirm `components.agentsRoseyRegrets.enabled: true`
- Confirm PVC name alignment:

  ```bash
  oc get pvc agent-reference-information -n test-range
  oc describe deploy rosey-regrets -n test-range
  ```

### RHACS Policy Not Firing

- Confirm Secured Cluster Services are connected to Central
- Verify policy was imported and is not disabled
- Confirm violation scope matches namespace `test-range`
- Validate notifier name exactly matches `Mattermost Notifier`

### Kagenti API Script Returns 401/404

- Verify `KAGENTI_API_BASE` and token
- Adjust `KAGENTI_COMMANDS_PATH_TEMPLATE` for your Kagenti version
- Set `KAGENTI_TLS_INSECURE=true` only for lab clusters with self-signed certs

---

## Security and Legal Notes

### Lab-Only Agent Behavior

**Rosey Regrets** is intentionally configured to perform network discovery using `nmap` against RFC1918 address space. This agent must **only** be deployed in:

- Isolated lab clusters
- Environments where you have explicit authorization to scan
- Networks designed for security evaluation and demonstration

Unauthorized scanning of production or third-party networks may violate policy and law.

### Secrets Management

- **Quay pull password:** set `QUAY_REGISTRY_PASSWORD` when running `discover-cluster-values.sh`, or edit `quayStorage.registryCredentials.password` in values (default placeholder in repo).
- **Mattermost bootstrap passwords:** configured under `mattermost.bootstrap` in `values.yaml` — change before non-lab use.
- Prefer External Secrets Operator, Sealed Secrets, or OpenShift GitOps vault integration for production.
- Optionally gitignore `values-cluster.yaml` if it contains secrets (see `.gitignore` comment).

### Privileged Workloads

The OpenShell SCC and buildah Tekton tasks require elevated privileges. Restrict namespace access and audit SCC usage.

---

## Development and Validation

### Local Helm Rendering

```bash
make helm-template-discovery
make cluster-values    # optional override file
make helm-template
```

### Full PoC Render (with component toggles)

```bash
helm template acs-ai-overwatch gitops/helm/acs-ai-overwatch \
  -f gitops/helm/acs-ai-overwatch/values.yaml \
  -f gitops/helm/acs-ai-overwatch/values-poc.yaml \
  -f gitops/helm/acs-ai-overwatch/values-cluster.yaml \
  --set components.acsPolicies.enabled=true \
  --set components.agentsRoseyRegrets.enabled=true \
  --set components.kagenti.enabled=true \
  > /tmp/acs-ai-overwatch-render.yaml
```

### Lint / Diff Before Upgrade

```bash
helm upgrade acs-ai-overwatch gitops/helm/acs-ai-overwatch \
  -f gitops/helm/acs-ai-overwatch/values.yaml \
  -f gitops/helm/acs-ai-overwatch/values-poc.yaml \
  -f gitops/helm/acs-ai-overwatch/values-cluster.yaml \
  --dry-run --debug
```

### Scratch Directory

Files under `scratch/` are **not** deployed by the Helm chart. They contain reference manifests, dashboards, and exploratory OpenShift AI setup YAML for local experimentation.

---

## Quick Reference Commands

```bash
oc login ...
make cluster-admin-pre-gitops

# Register GitOps Applications
oc apply -k gitops/argocd/
oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config

# Optional: local values file
make cluster-values
make helm-template
make helm-template-discovery

# Apply Tekton pipeline
oc apply -n acs-ai-overwatch-system -f pipelines/tekton/agents-build-pipeline.yaml

# Build agent images (example PipelineRun)
oc create -n acs-ai-overwatch-system -f pipelines/tekton/agents-build-pipelinerun.example.yaml

# Trigger Rosey network audit
export KAGENTI_API_BASE="$(kubectl get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config -o jsonpath='{.data.kagentiApiBaseUrl}')"
export KAGENTI_API_TOKEN="<token>"
./scripts/trigger-network-audit.sh

# Check test-range workloads
oc get all,pvc,cm -n test-range
```

---

## Contributing

When extending this repository:

1. Add new optional features behind `components.*` toggles in `values.yaml`
2. Keep namespace and naming conventions consistent with `test-range` isolation model
3. Document new cluster-specific settings in this README, `values-cluster.yaml.example`, and the discovery ConfigMap keys
4. Validate with `helm template` before opening a PR
5. Do not commit secrets, kubeconfigs, or environment-specific credentials

---

## License

Refer to your organization's licensing terms for Red Hat OpenShift, OpenShift AI, Advanced Cluster Security, and third-party components (NVIDIA OpenShell, Mattermost, Kagenti, Hugging Face models).
