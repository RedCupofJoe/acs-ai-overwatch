# Cluster-admin scripts (before Argo CD)

Run these **on your workstation** as a **cluster admin** after `oc login` and **before** `oc apply -k gitops/argocd/`.

**Manual OperatorHub installs (not covered by scripts here):** [Red Hat Kueue Operator](../README.md#red-hat-kueue-operator-prerequisite) (before `default-dsc`), [OpenShift Pipelines](../README.md#openshift-pipelines-tekton-prerequisite) (before agent builds).

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
