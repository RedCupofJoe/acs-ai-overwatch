# Cluster setup

Only **`05-aws-gpu-machineset`** is vendored here (workshop `00-cluster-setup` has other labs this PoC does not use).

Creates or clones an AWS MachineSet, taints nodes `nvidia.com/gpu=NoSchedule`, and scales to `GPU_REPLICAS`.

```bash
oc apply -k configs/00-cluster-setup/05-aws-gpu-machineset
```

PoC defaults in `job.yaml`:

| Env | Default | Notes |
|-----|---------|--------|
| `INSTANCE_TYPE` | `g6.12xlarge` | 4× L4 on one node. Do not use 3× `g6.4xlarge`. |
| `GPU_REPLICAS` | `1` | One GPU node |
| `NODE_VOLUME_SIZE` | `250` | GiB |
| `ENABLE_GPU_AUTOSCALE` | `false` | Set `true` only if you want 0–4 autoscaling |

On non-AWS clusters the Job succeeds without creating a MachineSet.

Re-run after changing env: `oc delete job job-aws-gpu-machineset -n nvidia-gpu-operator` then apply again (or `05-apply-platform-prep.sh --reset-machineset-job`).

`--reset-machineset-job` re-applies `GPU_REPLICAS` (default 1). If you already scaled the GPU MachineSet higher, do not reset — the Job only failed the scale call, not provisioning.
