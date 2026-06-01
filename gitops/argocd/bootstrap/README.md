# OpenShift GitOps bootstrap

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
