# Cluster prep overlays (vendored)

Kustomize trees copied from [redhat-ai-americas/rhoai-installation-workshop-v2](https://github.com/redhat-ai-americas/rhoai-installation-workshop-v2) (`3.5` branch) so GPU nodes and NFD can be applied **before** Argo CD.

These overlays are **not** in `gitops/argocd/`. GitOps remains the source of truth for:

| Resource | Owner | Why |
|----------|--------|-----|
| `ClusterPolicy/gpu-cluster-policy` | Helm `accelerators-gpu-clusterpolicy.yaml` | Time-slices GPU 0 as `nvidia.com/gpu.shared` (workshop ClusterPolicy does not) |
| `DataScienceCluster/default-dsc` | Helm | PoC keeps `kueue.managementState: Removed`, OGX Managed |
| Tempo operator | Observability chart | Workshop OperatorGroup name would create a second OG in `openshift-tempo-operator` |

## Safe apply (recommended)

After `install-pre-gitops.sh`:

```bash
./scripts/cluster-admin/05-apply-platform-prep.sh
# or: make platform-prep
```

Default applies:

1. `00-cluster-setup/05-aws-gpu-machineset` — one `g6.12xlarge` (4× L4). No-op on non-AWS (Job exits 0).
2. `01-nvidia-gpu-operator/00` NFD operator, `01` GPU operator, `02` NFD instance (Helm does not create `NodeFeatureDiscovery`).

Default **skips**:

- `01/.../03-nvidia-gpu-instance` (workshop ClusterPolicy)
- `02-nvidia-gpu-workload` (optional CUDA smoke pods; consume `nvidia.com/gpu`)
- `03-rhoai-operator-dependencies` (Kueue/Tempo/Kuadrant not required for this PoC)
- `04-rhoai-setup` including `01-datasciencecluster`

## What we changed vs upstream

- OperatorGroup names match Helm: `openshift-nfd`, `nvidia-gpu-operator`, `redhat-ods-operator` (empty `spec`), Tempo `tempo-product`.
- AWS MachineSet Job defaults: `INSTANCE_TYPE=g6.12xlarge`, `GPU_REPLICAS=1`, `ENABLE_GPU_AUTOSCALE=false` (workshop autoscaled 0–4 and never provisioned a node).

Three `g6.4xlarge` (1× L4 each) would time-slice **every** GPU 0 and leave no dedicated `nvidia.com/gpu` for Gemma/Granite. This PoC uses **one `g6.12xlarge`**.

## Optional flags

See `./scripts/cluster-admin/05-apply-platform-prep.sh --help`.
