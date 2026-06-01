# OpenShift GitOps bootstrap

## AppProject `acs-ai-overwatch`

The umbrella chart deploys cluster-scoped CRs (RHOAI `DataScienceCluster`, GPU `ClusterPolicy`, `Namespace`, optional SCC). Apply **`gitops/argocd/appproject-acs-ai-overwatch.yaml`** before syncing the main Application, or sync fails with:

`one or more synchronization tasks are not valid`

(Underlying message is often `resource … is not permitted in project default`.)

All three Applications use `spec.project: acs-ai-overwatch` (see `gitops/argocd/kustomization.yaml`).

## Preferred: managed namespaces (GitOps Application)

Application **`acs-ai-overwatch-gitops-bootstrap`** (sync-wave `0`) creates PoC namespaces with:

```yaml
argocd.argoproj.io/managed-by: openshift-gitops
```

The OpenShift GitOps Operator then grants the application controller permission to create **ServiceAccounts**, Secrets, and other namespaced resources in those namespaces **before** discovery and the main chart sync.

**Order:** bootstrap → cluster-discovery → acs-ai-overwatch

After the bootstrap Application is **Synced**, wait a few seconds for the operator to reconcile RoleBindings, then sync discovery.

## Fallback: cluster-admin binding

If `managed-by` is not enabled on your cluster or sync still fails with `serviceaccounts is forbidden`:

```bash
oc apply -f gitops/argocd/bootstrap/openshift-gitops-controller-rbac.yaml
```

Then **Sync** discovery and main Applications.

This binding grants `cluster-admin` to the application controller (broad; use only for PoC). Adjust `subjects` if your instance uses a different service account name.
