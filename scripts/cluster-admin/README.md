# Cluster-admin scripts (before Argo CD)

Run these **on your workstation** as a **cluster admin** after `oc login` and **before** `oc apply -k gitops/argocd/`.

These scripts satisfy the pre-GitOps steps in [Argo CD GitOps setup and troubleshooting](../../docs/argocd-gitops.md). OpenShift AI on a clean cluster is [Red Hat OpenShift AI setup for a clean build](../../docs/redhat-openshift-ai.md). The install order for the demo is [Demo setup](../../docs/demo-setup.md).

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
| `05-apply-platform-prep.sh` | AWS GPU MachineSet, NFD/GPU operators, NFD instance, `nvidia.com/device-plugin.config=shared`, Service Mesh 3 (not cert-manager, ClusterPolicy, or DSC) |
| `enable-kata.sh` | Optional. Sets the trust-plane Kata flag (`--platform baremetal` or `--platform aws`). Off by default |

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

Sync order: `acs-ai-overwatch-gitops-bootstrap` → `acs-ai-overwatch-cluster-discovery` → `acs-ai-overwatch` → `acs-ai-overwatch-observability`. The full Application matrix is in [Argo CD GitOps setup and troubleshooting](../../docs/argocd-gitops.md).

## Manual steps (if necessary)

These scripts automate the pre-GitOps bootstrap. GPU MachineSet and NFD instance are **`05-apply-platform-prep.sh`** ([`configs/README.md`](../../configs/README.md)). The rest of the install is [Demo setup](../../docs/demo-setup.md).

### Before Phase 0 (this directory)

| When | Action |
|------|--------|
| First deploy on a cluster | Run `./scripts/cluster-admin/install-pre-gitops.sh` then `./scripts/cluster-admin/05-apply-platform-prep.sh` |
| Using a fork | Set `spec.source.repoURL` in each `gitops/argocd/application*.yaml` — scripts do not update Argo Application sources |
| Storage class differs from `gp3-csi` | Set `storage.defaultStorageClass` in chart `values.yaml` before sync — see [Red Hat OpenShift](../../docs/redhat-openshift.md) |
| Local Helm only | `./scripts/cluster-admin/install-pre-gitops.sh --with-values-file` writes `values-cluster.yaml`. Commit it when Argo CD should use those hostnames — see [Argo CD GitOps](../../docs/argocd-gitops.md) |

### Phase 0 — not covered by these scripts

| When | Action |
|------|--------|
| Before `default-dsc` syncs | **Nothing extra** — DSC keeps `kueue.managementState: Removed`. Do not install Kueue. |
| Enabling Quay | Set `quayStorage.registryCredentials.password` and the S3 credentials in values — see [Demo setup](../../docs/demo-setup.md) |
| Mattermost bootstrap | Set `mattermost.bootstrap.*` passwords in `values.yaml` |
| Quay operator stuck | Delete the unreferenced CSV — see [Argo CD GitOps](../../docs/argocd-gitops.md) |
| Helm `lookup` empty | Optional CMP — [Argo CD GitOps](../../docs/argocd-gitops.md) |

### Later work

| Topic | Guide |
|-------|--------|
| OpenShift AI 3.5, GPUs, DataScienceCluster | [Red Hat OpenShift AI setup for a clean build](../../docs/redhat-openshift-ai.md) |
| Agents, images, Mattermost, ACS, TPA | [Demo setup](../../docs/demo-setup.md) |
| Presenting the story | [PoC demo walkthrough](../../docs/poc-demo-walkthrough.md) |
| After PoC (repo reset) | [cleanup-poc-repo.sh](../cleanup-poc-repo.sh) — baseline GitOps, no cluster changes |
