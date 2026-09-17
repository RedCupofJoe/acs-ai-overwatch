# NVIDIA GPU Workload

> **PoC:** Optional CUDA smoke test: `./scripts/cluster-admin/05-apply-platform-prep.sh --smoke-test` after GPUs are advertised. Pods request `nvidia.com/gpu` (dedicated), not `nvidia.com/gpu.shared`.

Deploys sample GPU workloads to verify that NVIDIA GPUs are installed, advertised, and schedulable.


## Objectives

- Run a CUDA vector-add sample that requests one GPU
- Confirm driver and CUDA versions via `nvidia-smi`

## Rationale

Validates end-to-end GPU bootstrap before installing RHOAI or scheduling production ML workloads.

## Takeaways

- Researchers can schedule GPU pods without additional subscriptions once the GPU Operator is healthy
- `nvidia-smi` reports driver and CUDA versions managed by the operator
- PodSecurity warnings during sample deployment are expected when only auditing Pod Security Admission

## Documentation

- [NVIDIA GPU Operator documentation](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html)
- [Running a sample GPU application](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/install-gpu-ocp.html#running-a-sample-gpu-application)
- [OpenShift Container Platform hardware accelerators](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/hardware_accelerators/index)

## Setup Steps

### 00 - GPU Test Namespace

Creates a sandbox namespace for GPU validation workloads.

**Documentation:** [Managing projects and namespaces](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/building_applications/projects)

```bash
oc apply -k configs/02-nvidia-gpu-workload/00-gpu-test-namespace
```

### 01 - NVIDIA GPU Workload

Runs a CUDA vector-add sample pod that requests one NVIDIA GPU.

**Documentation:** [NVIDIA GPU Operator on OpenShift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/install-gpu-ocp.html)

```bash
oc apply -k configs/02-nvidia-gpu-workload/01-nvidia-gpu-workload
```

**Validation:**

```bash
oc logs cuda-vectoradd -n gpu-test
```

Expected log lines include `Test PASSED` and `Done`.

### 02 - NVIDIA GPU nvidia-smi

Runs an `nvidia-smi` pod to display GPU device information from a scheduled workload.

**Documentation:** [Hardware accelerators](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/hardware_accelerators/index)

```bash
oc apply -k configs/02-nvidia-gpu-workload/02-nvidia-gpu-nvidia-smi
```

**Validation:**

```bash
oc get pods -n gpu-test
oc exec -itn nvidia-gpu-operator \
  $(oc get pod -n nvidia-gpu-operator -l app=nvidia-smi -ojsonpath='{.items[0].metadata.name}') \
  -- nvidia-smi
```
