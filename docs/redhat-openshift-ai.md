# Red Hat OpenShift AI setup for a clean build

OpenShift AI 3.5 (`stable-3.5`) on a cluster that has never had Red Hat OpenShift AI 2.25. A leftover 2.25 install fights the 3.5 CSV.

Start from [Red Hat OpenShift](redhat-openshift.md). After this guide, install the demo with [Demo setup](demo-setup.md).

Other guides: [Argo CD GitOps](argocd-gitops.md) · [PoC demo walkthrough](poc-demo-walkthrough.md)

## What this build includes

- OpenShift AI 3.5 from `redhat-operators`, channel `stable-3.5` (discovery may select `fast-3.5` or `eus-3.5`; override the minor with `RHOAI_TARGET_VERSION`, default `3.5`)
- One `g6.12xlarge` (4× NVIDIA L4) with GPU Operator 26.3 time-slicing
- Node Feature Discovery and the label that turns time-slicing on
- Service Mesh 3, which OGX requires
- A DataScienceCluster that leaves Kueue and product MaaS removed
- Gemma and Granite as Model Catalog ModelCar images behind `LLMInferenceService`

The Helm chart owns the `DataScienceCluster` and the GPU `ClusterPolicy`. `05-apply-platform-prep.sh` does not create those two objects.

## 1. Confirm the cluster is a clean 3.5 target

```bash
oc get csv -A | grep -E 'rhods|openshift-ai' || true
oc get datasciencecluster -A || true
```

Remove a previous OpenShift AI install before subscribing to 3.5. The OperatorGroup in `redhat-ods-operator` must be `spec: {}` (all namespaces). `targetNamespaces` on that group fails the CSV.

```bash
oc get operatorgroup -n redhat-ods-operator -o yaml
```

## 2. Turn on User Workload Monitoring

This is a Models-as-a-Service prerequisite. `check-prereqs.sh` warns when it is off. The observability chart also enables it. To set it yourself:

```bash
oc get configmap cluster-monitoring-config -n openshift-monitoring || \
  oc create configmap cluster-monitoring-config -n openshift-monitoring \
    --from-literal=config.yaml=$'enableUserWorkload: true\n'
```

## 3. Prepare GPUs and Service Mesh

```bash
./scripts/cluster-admin/05-apply-platform-prep.sh
# or: make platform-prep
```

That script creates the AWS GPU MachineSet, subscribes NFD and the GPU Operator, creates the `NodeFeatureDiscovery` instance, labels the NVIDIA node `nvidia.com/device-plugin.config=shared`, and subscribes Service Mesh 3 (`servicemeshoperator3`, channel `stable`).

It does not install cert-manager, the workshop ClusterPolicy, or the DataScienceCluster.

GPU Operator 26.3 time-slicing is per node. The device plugin ignores a per-GPU `devices` list and `rename`. The `shared` key in ConfigMap `time-slicing-config` keeps `renameByDefault: false` and replicates `nvidia.com/gpu` on every L4 (4 GPUs × 4 replicas = 16 slots). Agents, the builder, Gemma, and Granite each request `nvidia.com/gpu: 1`. GPU pods tolerate the `nvidia.com/gpu` NoSchedule taint from the AWS MachineSet.

NVIDIA time-slicing does not isolate VRAM. vLLM is set to `gpuMemoryUtilization: 0.75` so one MiniCPM sidecar can share a 24 GB L4 with Gemma or Granite. Two vLLM pods on the same physical L4 still run out of memory. The device plugin normally spreads the first four GPU pods across the four L4s.

| Slots | Resource | Workloads |
| --- | --- | --- |
| 16 | `nvidia.com/gpu: "1"` | Hank, Rosey, Sam, builder, Gemma, Granite |

Service Mesh 3 is also subscribed by the Helm chart. Use the existing control plane. Do not create a second Istio installation.

## 4. Let GitOps create the DataScienceCluster

The chart’s DataScienceCluster keeps:

| Component | managementState | Why |
| --- | --- | --- |
| Kueue | `Removed` | OpenShift AI 3.5 rejects `Managed` for Kueue. Install the Kueue operator only if you later change this field |
| Product MaaS (`aigateway`) | `Removed` | The demo front door is the API proxy in `acs-maas` |

Inference uses `LLMInferenceService` and Gateway `openshift-ai-inference` in `openshift-ingress`. That Gateway uses GatewayClass `data-science-gateway-class`, which OpenShift AI creates from GatewayConfig `default-gateway`. The dashboard Gateway is a different object (`data-science-gateway`) and is not the serving path. Certificate `openshift-ai-inference-tls` comes from the cert-manager operator already on the cluster. The chart does not install that operator. See [Red Hat OpenShift](redhat-openshift.md).

GPU pods request `nvidia.com/gpu` and tolerate the GPU taint. They are not pinned to a node label. A `nodeSelector` in `values-cluster.yaml` is only for a cluster that has actually labeled a pool.

Register the Argo CD Applications with [Demo setup](demo-setup.md) and the [GitOps guide](argocd-gitops.md). `values-poc.yaml` sets `platformResources.waitForCrds: false`, so the first sync renders the DataScienceCluster before the operator CSV is `Succeeded`. Refresh the Application after the CSV succeeds.

## 5. Verify 3.5 before expecting `default-dsc`

```bash
oc get csv -n redhat-ods-operator \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase | grep rhods
oc get crd datascienceclusters.datasciencecluster.opendatahub.io \
  -o jsonpath='{.spec.versions[*].name}{"\n"}'
oc get datasciencecluster -A
oc get nodes -l nvidia.com/gpu.present -o custom-columns=NAME:.metadata.name,GPU:.metadata.labels.nvidia\\.com/device-plugin\\.config
```

The CSV must be a 3.5 release, and the CRD must serve the version the chart uses. The GPU node label must be `shared`.

## Model Catalog

Investigator Gemma and MaaS Granite are `LLMInferenceService` custom resources. `spec.model.uri` is the catalog ModelCar image:

- `oci://registry.redhat.io/rhelai1/modelcar-gemma-2-9b-it-fp8:1.5`
- `oci://registry.redhat.io/rhelai1/modelcar-granite-3-1-8b-instruct-fp8-dynamic:1.5`

OpenShift pulls them with the cluster pull secret, the same path as **AI hub → Models Catalog**. Rogue MiniCPM GGUF still comes from Hugging Face inside the shadow agent pod.

## Troubleshooting

### RHOAI CSV `Failed` or `TooManyOperatorGroups`

The OperatorGroup in `redhat-ods-operator` must be `spec: {}`, and there can be only one. The chart owns `redhat-ods-operator`. A console install often leaves a second group such as `rhods-operator-group`, and the CSV fails with `TooManyOperatorGroups`. `05-apply-platform-prep.sh` deletes every group in that namespace except `redhat-ods-operator`. A second cert-manager OperatorGroup produces the same failure on the cert-manager CSV. Delete the extra group. Leave the original cert-manager Subscription in place.

### DataScienceCluster `Managed is no longer supported`

OpenShift AI 3.5 rejects `kueue.managementState: Managed`. The chart sets `Removed`.

### GPU slices are missing

Confirm the node label `nvidia.com/device-plugin.config=shared` and that the GPU Operator CSV is `Succeeded`. `make platform-prep` creates the `NodeFeatureDiscovery` instance and sets that label. The ClusterPolicy arrives with the main Helm chart, not with the prep script.
