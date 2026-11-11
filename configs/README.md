# Cluster prep overlays (vendored)

Kustomize trees copied from [redhat-ai-americas/rhoai-installation-workshop-v2](https://github.com/redhat-ai-americas/rhoai-installation-workshop-v2) (`3.5` branch) so GPU nodes and NFD can be applied **before** Argo CD.

These overlays are **not** in `gitops/argocd/`. GitOps remains the source of truth for:

| Resource | Owner | Why |
|----------|--------|-----|
| `ClusterPolicy/gpu-cluster-policy` | Helm `accelerators-gpu-clusterpolicy.yaml` | Time-slices every GPU on a node labeled `nvidia.com/device-plugin.config=shared` as `nvidia.com/gpu` |
| `DataScienceCluster/default-dsc` | Helm | PoC keeps `kueue.managementState: Removed`, OGX Managed |
| Tempo operator | Observability chart | Workshop OperatorGroup name would create a second OG in `openshift-tempo-operator` |

## Safe apply (recommended)

After `install-pre-gitops.sh`:

```bash
./scripts/cluster-admin/05-apply-platform-prep.sh
# or: make platform-prep
```

Default applies:

1. `00-cluster-setup/05-aws-gpu-machineset` — one `g6.12xlarge` (4× L4), including label `nvidia.com/device-plugin.config=shared` on the node template. No-op on non-AWS (Job exits 0).
2. `01-nvidia-gpu-operator/00` NFD operator, `01` GPU operator, `02` NFD instance (Helm does not create `NodeFeatureDiscovery`).
3. Label any NVIDIA node that is already joined, and patch existing GPU MachineSets with the same label.
4. `03/.../12-servicemesh-operator` (OGX prerequisite). cert-manager Operator is already installed and is not applied again.

Default **skips**:

- `01/.../03-nvidia-gpu-instance` (workshop ClusterPolicy)
- `02-nvidia-gpu-workload` (optional CUDA smoke pods; consume `nvidia.com/gpu`)
- The rest of `03-rhoai-operator-dependencies` (LWS, JobSet, OTEL, COO, Kueue, Tempo, Kuadrant)
- `04-rhoai-setup` including `01-datasciencecluster`

## What we changed vs upstream

- OperatorGroup names match Helm: `nfd`, `nvidia-gpu-operator`, `redhat-ods-operator` (empty `spec`), Tempo `tempo-product`. One group per namespace. cert-manager keeps the OperatorGroup the cluster already has.
- AWS MachineSet Job defaults: `INSTANCE_TYPE=g6.12xlarge`, `GPU_REPLICAS=1`, `ENABLE_GPU_AUTOSCALE=false` (workshop autoscaled 0–4 and never provisioned a node).

This PoC uses **one `g6.12xlarge`** so four L4s exist. Time-slicing applies to every GPU on the labeled node and keeps the resource name `nvidia.com/gpu`.

## Optional flags

See `./scripts/cluster-admin/05-apply-platform-prep.sh --help`.
