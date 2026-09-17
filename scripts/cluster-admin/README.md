# Cluster-admin scripts (before Argo CD)

Run these **on your workstation** as a **cluster admin** after `oc login` and **before** `oc apply -k gitops/argocd/`.

These scripts satisfy **Phase 0** prerequisites documented in the main [README — PoC deployment phases](../../README.md#poc-deployment-phases). For later phases (agents, RHACS, observability), see the **Manual steps (if necessary)** subsection under each phase in that README.

## One command (recommended)

```bash
chmod +x scripts/cluster-admin/*.sh
./scripts/cluster-admin/install-pre-gitops.sh
./scripts/cluster-admin/05-apply-platform-prep.sh   # or: make platform-prep
```

## Step by step

| Script | What it creates |
|--------|-----------------|
| `00-apply-appproject.sh` | AppProject `acs-ai-overwatch` (cluster-scoped CRs for the main chart) |
| `01-grant-openshift-gitops-rbac.sh` | `ClusterRoleBinding` so `openshift-gitops-argocd-application-controller` can deploy ServiceAccounts, operators, SCCs, etc. |
| `02-bootstrap-namespaces.sh` | PoC namespaces with `argocd.argoproj.io/managed-by=openshift-gitops` |
| `03-apply-cluster-configmap.sh` | ConfigMap `acs-ai-overwatch-system/acs-ai-overwatch-cluster-config` (`appsDomain`, Quay host, git URL) |
| `04-apply-discovery-prerequisites.sh` | ServiceAccount `cluster-discovery`, RBAC, ConfigMap `cluster-discovery-script` |
| `05-apply-platform-prep.sh` | AWS GPU MachineSet + NFD/GPU operators + NFD instance (not ClusterPolicy/DSC) |

## Options

```bash
# If managed-by namespaces are enough on your cluster (no cluster-admin binding):
./scripts/cluster-admin/install-pre-gitops.sh --skip-rbac

# Let Argo CD create discovery SA/ConfigMap instead:
./scripts/cluster-admin/install-pre-gitops.sh --skip-discovery-prereqs

# Also write gitops/helm/acs-ai-overwatch/values-cluster.yaml for local helm:
./scripts/cluster-admin/install-pre-gitops.sh --with-values-file

# GPU MachineSet + NFD (after bootstrap); see configs/README.md
./scripts/cluster-admin/05-apply-platform-prep.sh
./scripts/cluster-admin/05-apply-platform-prep.sh --skip-machineset   # non-AWS / GPUs already present
```

## Environment variables

| Variable | Default | Used by |
|----------|---------|---------|
| `CLUSTER_CONFIG_NAMESPACE` | `acs-ai-overwatch-system` | `03-apply-cluster-configmap.sh` |
| `CLUSTER_CONFIG_NAME` | `acs-ai-overwatch-cluster-config` | `03-apply-cluster-configmap.sh` |
| `GIT_REPO_URL_DEFAULT` | GitHub default in chart | discovery scripts |
| `DISCOVERY_NAMESPACE` | `acs-ai-overwatch-system` | `04-apply-discovery-prerequisites.sh` |
| `GIT_REPO_URL` | auto / git remote | discovery lib |

## Verify

```bash
oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config
oc get sa -n acs-ai-overwatch-system cluster-discovery
oc auth can-i create serviceaccounts -n acs-ai-overwatch-system \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
```

## Then deploy with Argo CD

```bash
# Edit values-poc.yaml, set repoURL in gitops/argocd/application*.yaml, then:
oc apply -k gitops/argocd/
```

Sync order: `acs-ai-overwatch-gitops-bootstrap` → `acs-ai-overwatch-cluster-discovery` → `acs-ai-overwatch` → `acs-ai-overwatch-observability`. Full phase map: [README — Recommended order summary](../../README.md#recommended-order-summary).

## Manual steps (if necessary)

These scripts automate the **pre-GitOps bootstrap**. GPU MachineSet and NFD instance are **`05-apply-platform-prep.sh`** ([`configs/README.md`](../../configs/README.md)). Other manual work is grouped by PoC phase in the main README.

### Before Phase 0 (this directory)

| When | Action |
|------|--------|
| First deploy on a cluster | Run `./scripts/cluster-admin/install-pre-gitops.sh` then `./scripts/cluster-admin/05-apply-platform-prep.sh` |
| Using a fork | Set `spec.source.repoURL` in each `gitops/argocd/application*.yaml` — scripts do not update Argo Application sources |
| Storage class ≠ `gp3-csi` | Set `storage.defaultStorageClass` in chart `values.yaml` before sync — see [README — Storage](../../README.md#storage) |
| Local Helm only | `./scripts/cluster-admin/install-pre-gitops.sh --with-values-file` writes `values-cluster.yaml` (optional; do not commit sandbox hostnames) |

### Phase 0 — not covered by these scripts

| When | Action |
|------|--------|
| Before `default-dsc` syncs | **Nothing extra** — DSC keeps `kueue.managementState: Removed`. Do not install Kueue. |
| Enabling Quay | Set `quayStorage.registryCredentials.password` and MinIO credentials in values — see [Phase 0 manual steps](../../README.md#phase-0--gitops-bootstrap-default) |
| Mattermost bootstrap | Set `mattermost.bootstrap.*` passwords in `values.yaml` |
| Quay operator stuck | Orphan CSV cleanup — see [Phase 0 manual steps](../../README.md#phase-0--gitops-bootstrap-default) |
| Helm `lookup` empty | Optional CMP — [README — Cluster-Aware Configuration](../../README.md#cluster-aware-configuration) |

### Later phases — see main README

| Phase | Manual steps doc |
|-------|------------------|
| Phase 1 — Mattermost URL | [README — Phase 1](../../README.md#phase-1--mattermost-deploy-automatic-with-baseline) |
| Phase 2 — Agents | [README — Phase 2](../../README.md#phase-2--agents-poc-overlay) (+ [OpenShift Pipelines](../../README.md#openshift-pipelines-tekton)) |
| Phase 3 — Full RHACS | [README — Phase 3](../../README.md#phase-3--full-rhacs-central--securedcluster-on-in-values-pocyaml) |
| Phase 4 — Investigator / MaaS / builder | [README — Architecture](../../README.md#architecture) |
| Phase 5 — Observability | [README — Phase 5](../../README.md#phase-5--shared-observability-option-c-otel--tempo--mlflow--grafana-on-by-default) |
| After PoC (repo reset) | [cleanup-poc-repo.sh](../cleanup-poc-repo.sh) — baseline GitOps, no cluster changes |
