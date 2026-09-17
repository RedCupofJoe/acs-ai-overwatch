# NVIDIA GPU Operator

> **PoC:** Apply with `./scripts/cluster-admin/05-apply-platform-prep.sh`. Do **not** apply `03-nvidia-gpu-instance` unless you pass `--with-gpu-clusterpolicy` — Helm owns `ClusterPolicy/gpu-cluster-policy` (GPU 0 time-slicing). See [configs/README.md](../README.md).
>
> OperatorGroup names were aligned with Helm (`openshift-nfd`, `nvidia-gpu-operator`) so OLM is not given two OperatorGroups in one namespace.

Installs and configures the NVIDIA GPU Operator stack so the cluster discovers GPUs, installs drivers, and advertises `nvidia.com/gpu` for scheduling.


## Objectives

- Discover GPU hardware with Node Feature Discovery (NFD)
- Install NVIDIA drivers, device plugin, DCGM, and container toolkit via the GPU Operator
- Expose GPU metrics in the OpenShift console

## Rationale

RHOAI does not install or manage GPU drivers. NFD labels nodes with PCI vendor IDs (for example `nvidia.com/gpu.product: NVIDIA-L40S`), and the GPU Operator installs the stack required for CUDA workloads.

## Takeaways

- NFD uses PCI device class whitelists and vendor IDs to label hardware features on nodes
- The NVIDIA device plugin exposes `nvidia.com/gpu`; MIG strategy and time-slicing are configurable on the ClusterPolicy
- Wait 10–20 minutes after ClusterPolicy apply before troubleshooting; driver pods must reach `2/2` Ready
- `nvidia.com/gpu` identifies GPU capacity, not GPU model; use node selectors, affinity, or Kueue for finer placement

## Documentation

- [NVIDIA GPU Operator documentation](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html)
- [NVIDIA GPU Operator on Red Hat OpenShift Container Platform](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/install-gpu-ocp.html)
- [OpenShift Container Platform hardware accelerators](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/hardware_accelerators/index)

## Setup Steps

### 00 - NFD Operator

Installs the Node Feature Discovery (NFD) operator, which labels nodes based on hardware capabilities such as GPUs.

**Documentation:** [Node Feature Discovery in OpenShift hardware accelerators](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/hardware_accelerators/index)

```bash
oc apply -k configs/01-nvidia-gpu-operator/00-nfd-operator
```

**Validation:**

```bash
oc get installplan -n openshift-nfd
oc get csv -n openshift-nfd
oc get pods -n openshift-nfd
```

### 01 - NVIDIA GPU Operator

Installs the NVIDIA GPU Operator, which manages NVIDIA drivers, device plugins, and related GPU components on the cluster.

**Documentation:** [Installing the NVIDIA GPU Operator on OpenShift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/install-gpu-ocp.html)

```bash
oc apply -k configs/01-nvidia-gpu-operator/01-nvidia-gpu-operator
```

**Validation:**

```bash
oc get installplan -n nvidia-gpu-operator
oc get csv -n nvidia-gpu-operator
oc get pods -n nvidia-gpu-operator
```

### 02 - NFD Instance

Creates a NodeFeatureDiscovery instance so NFD begins labeling nodes with detected hardware features.

**Documentation:** [Node Feature Discovery Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/specialized_hardware_and_driver_enablement/psap-node-feature-discovery-operator)

```bash
oc apply -k configs/01-nvidia-gpu-operator/02-nfd-instance
```

**Validation:** Confirm GPU PCI labels on worker nodes (NVIDIA vendor ID `10de`):

```bash
oc describe node | egrep 'Roles|pci-10de' | grep -v master
```

### 03 - NVIDIA GPU Instance

Deploys the NVIDIA ClusterPolicy that configures drivers, device plugins, DCGM exporter, and GPU node tolerations for `nvidia.com/gpu`.

**Documentation:** [Create the ClusterPolicy instance on OpenShift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/install-gpu-ocp.html#create-the-clusterpolicy-instance)

```bash
oc apply -k configs/01-nvidia-gpu-operator/03-nvidia-gpu-instance
```

**Validation:**

```bash
oc get pod -l openshift.driver-toolkit -n nvidia-gpu-operator -w
```

Driver pods must reach `2/2` Ready before GPUs are schedulable. Label GPU nodes for readability:

```bash
oc get nodes
```

### 04 - Optional NVIDIA Monitoring Dashboard

Adds a DCGM exporter Grafana dashboard to the OpenShift console for viewing GPU metrics (utilization, memory, temperature, power, tensor core usage).

**Rationale:** Provides system-level GPU monitoring for capacity planning and usage, not functional ML model monitoring.

**Documentation:** [Enable the GPU monitoring dashboard](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/enable-gpu-monitoring-dashboard.html)

```bash
oc apply -k configs/01-nvidia-gpu-operator/04-optional-nvidia-monitoring-dashboard
```

**Validation:** In the OpenShift console, open **Observe** > **Dashboards** and locate the NVIDIA DCGM exporter dashboard (Administrator or Developer perspective).

### 05 - Optional NVIDIA Console Plugin

Enables the NVIDIA GPU console plugin so GPU status and metrics are visible in the OpenShift console.

**Documentation:** [NVIDIA GPU Operator on OpenShift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/index.html)

```bash
oc apply -k configs/01-nvidia-gpu-operator/05-optional-nvidia-console-plugin
```

## Additional Steps

Review GPU node pods in the OpenShift console. For GPU sharing (time-slicing, MPS, MIG), see [NVIDIA GPU sharing methods](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/time-slicing-gpus-in-openshift.html) and [OpenShift NVIDIA GPU architecture overview](https://docs.openshift.com/container-platform/4.20/architecture/nvidia-gpu-architecture-overview.html).
