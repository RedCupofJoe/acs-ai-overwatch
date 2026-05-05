# acs-ai-overwatch

GitOps deployment targets **OpenShift GitOps** (Argo CD).

- **Cluster values:** edit `gitops/helm/acs-ai-overwatch/values.yaml` (hosts, NVMe disk paths, secrets, `accelerators` for NFD + NVIDIA GPU Operator time-slicing, `rhoai` for OpenShift AI 3.2 / `DataScienceCluster` / `HardwareProfile`, and other feature toggles).
- **Register the app:** apply `gitops/argocd/application.yaml` into namespace `openshift-gitops` after pointing `spec.source.repoURL` at this repository.
- **Helm only:** `helm template acs-ai-overwatch gitops/helm/acs-ai-overwatch` or install from that path.

Placeholder directories (`bootstrap/operators`, `agents/*`, `pipelines`, etc.) are reserved for future manifests; enable them in `values.yaml` under `components.*` when content exists.
