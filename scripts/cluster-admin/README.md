# Cluster-admin scripts (before Argo CD)

Run these **on your workstation** as a **cluster admin** after `oc login` and **before** `oc apply -k gitops/argocd/`.

These scripts satisfy **Phase 0** prerequisites documented in the main [README — PoC deployment phases](../README.md#poc-deployment-phases). For manual steps in later phases (agents, RHACS, Kagenti, observability), see the **Manual steps (if necessary)** subsection under each phase in that README.

## One command (recommended)

```bash
chmod +x scripts/cluster-admin/*.sh
./scripts/cluster-admin/install-pre-gitops.sh
```

## Step by step

| Script | What it creates |
|--------|-----------------|
| `00-apply-appproject.sh` | AppProject `acs-ai-overwatch` (cluster-scoped CRs for the main chart) |
| `01-grant-openshift-gitops-rbac.sh` | `ClusterRoleBinding` so `openshift-gitops-argocd-application-controller` can deploy ServiceAccounts, operators, SCCs, etc. |
| `02-bootstrap-namespaces.sh` | PoC namespaces with `argocd.argoproj.io/managed-by=openshift-gitops` |
| `03-apply-cluster-configmap.sh` | ConfigMap `acs-ai-overwatch-system/acs-ai-overwatch-cluster-config` (`appsDomain`, Quay host, Kagenti URL, git URL) |
| `04-apply-discovery-prerequisites.sh` | ServiceAccount `cluster-discovery`, RBAC, ConfigMap `cluster-discovery-script` |

## Options

```bash
# If managed-by namespaces are enough on your cluster (no cluster-admin binding):
./scripts/cluster-admin/install-pre-gitops.sh --skip-rbac

# Let Argo CD create discovery SA/ConfigMap instead:
./scripts/cluster-admin/install-pre-gitops.sh --skip-discovery-prereqs

# Also write gitops/helm/acs-ai-overwatch/values-cluster.yaml for local helm:
./scripts/cluster-admin/install-pre-gitops.sh --with-values-file
```

## Environment variables

| Variable | Default | Used by |
|----------|---------|---------|
| `CLUSTER_CONFIG_NAMESPACE` | `acs-ai-overwatch-system` | `03-apply-cluster-configmap.sh` |
| `CLUSTER_CONFIG_NAME` | `acs-ai-overwatch-cluster-config` | `03-apply-cluster-configmap.sh` |
| `GIT_REPO_URL_DEFAULT` | GitHub default in chart | discovery scripts |
| `DISCOVERY_NAMESPACE` | `acs-ai-overwatch-system` | `04-apply-discovery-prerequisites.sh` |
| `KAGENTI_API_BASE_URL` | auto | discovery lib |
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

Sync order: `acs-ai-overwatch-gitops-bootstrap` → `acs-ai-overwatch-cluster-discovery` → `acs-ai-overwatch`. Full phase map: [README — Recommended order summary](../README.md#recommended-order-summary).

## Manual steps (if necessary)

These scripts automate the **pre-GitOps bootstrap**. Other manual work is grouped by PoC phase in the main README.

### Before Phase 0 (this directory)

| When | Action |
|------|--------|
| First deploy on a cluster | Run `./scripts/cluster-admin/install-pre-gitops.sh` (or `make cluster-admin-pre-gitops`) |
| Using a fork | Set `spec.source.repoURL` in each `gitops/argocd/application*.yaml` — scripts do not update Argo Application sources |
| Storage class ≠ `gp3-csi` | Set `storage.defaultStorageClass` in chart `values.yaml` before sync — see [README — Storage](../README.md#storage) |
| Local Helm only | `./scripts/cluster-admin/install-pre-gitops.sh --with-values-file` writes `values-cluster.yaml` (optional; do not commit sandbox hostnames) |

### Phase 0 — not covered by these scripts

| When | Action |
|------|--------|
| Before `default-dsc` syncs | Install [Red Hat Kueue Operator](../README.md#red-hat-kueue-operator-prerequisite) from OperatorHub |
| Enabling Quay | Set `quayStorage.registryCredentials.password` and MinIO credentials in values — see [Phase 0 manual steps](../README.md#phase-0--gitops-bootstrap-default) |
| Mattermost bootstrap | Set `mattermost.bootstrap.*` passwords in `values.yaml` |
| Quay operator stuck | Orphan CSV cleanup — see [Phase 0 manual steps](../README.md#phase-0--gitops-bootstrap-default) |
| Helm `lookup` empty | Optional CMP — [README — Cluster-Aware Configuration](../README.md#cluster-aware-configuration) |

### Later phases — see main README

| Phase | Manual steps doc |
|-------|------------------|
| Phase 1 — Mattermost URL | [README — Phase 1](../README.md#phase-1--mattermost-external-url-automatic) |
| Phase 2 — Agents | [README — Phase 2](../README.md#phase-2--agents-opt-in) (+ [OpenShift Pipelines prerequisite](../README.md#openshift-pipelines-tekton-prerequisite)) |
| Phase 3 — Full RHACS | [README — Phase 3](../README.md#phase-3--full-rhacs-central--securedcluster-opt-in-off-by-default) |
| Phase 4 — Kagenti | [README — Phase 4](../README.md#phase-4--kagenti-platform-opt-in-off-by-default) and [KEYCLOAK.md — manual steps](../gitops/helm/acs-ai-overwatch-kagenti-platform/KEYCLOAK.md#manual-steps-if-necessary) |
| Phase 5 — Observability | [README — Phase 5](../README.md#phase-5--shared-observability-option-c-otel--tempo--mlflow--grafana-opt-in-off-by-default) |
