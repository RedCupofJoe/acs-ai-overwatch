# Optional Argo CD Config Management Plugin (CMP)

OpenShift GitOps often renders Helm **without** a live API connection, so `lookup` in the main chart may not see the discovery ConfigMap. The default flow avoids that:

1. Sync **`acs-ai-overwatch-cluster-discovery`** (Job writes `acs-ai-overwatch-cluster-config`).
2. **Refresh** **`acs-ai-overwatch`** (gated templates enable Mattermost / Quay secrets / Kagenti once the ConfigMap exists and `lookup` works).

If `lookup` stays empty after discovery, install a CMP that runs `generate-helm-with-cluster-config.sh` on the repo-server (with cluster RBAC to read the ConfigMap). See [Argo CD CMP documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/config-management-plugins/).

```bash
chmod +x gitops/argocd/cmp/generate-helm-with-cluster-config.sh
```

Point the main `Application` `spec.source.plugin.name` at your registered plugin instead of `spec.source.helm`.
