# Red Hat OpenShift

Cluster foundation for ACS AI Overwatch. OpenShift AI on a clean cluster is the [next guide](redhat-openshift-ai.md).

Other guides: [Demo setup](demo-setup.md) · [Argo CD GitOps](argocd-gitops.md) · [PoC demo walkthrough](poc-demo-walkthrough.md)

## Version

| Requirement | Notes |
| --- | --- |
| OpenShift 4.20–4.22 | 4.19.9 and later can run OpenShift AI 3.5 when the operator channel matches the cluster |
| Operator catalogs | `redhat-operators` and `certified-operators` must be `READY` |
| OpenShift GitOps | Argo CD in `openshift-gitops`. Controller sizing is in the [GitOps guide](argocd-gitops.md) |
| Cluster admin | Required to install operators, SecurityContextConstraints, and other cluster-scoped resources |

Confirm the session before any script:

```bash
oc login
./scripts/check-prereqs.sh
oc get storageclass
oc get catalogsource -n openshift-marketplace
```

## Nodes

Use one AWS `g6.12xlarge` (4× NVIDIA L4, 24 GB each). Three `g6.4xlarge` nodes give one L4 each and are the wrong shape for this demo. How those GPUs are time-sliced is in the [OpenShift AI guide](redhat-openshift-ai.md).

## Storage

Persistent volumes use `gp3-csi` (AWS EBS). It is `WaitForFirstConsumer`: a claim stays `Pending` until a pod is scheduled. Argo CD has to treat that phase as healthy, or the next sync wave never starts. That health check is applied by `scripts/cluster-admin/install-pre-gitops.sh` and explained in the [GitOps guide](argocd-gitops.md).

If the class has another name, set `storage.defaultStorageClass` in `gitops/helm/acs-ai-overwatch/values.yaml`. Component PVCs fall back to that value when their own class is empty.

| Workload | Values key | Default size |
| --- | --- | --- |
| Mattermost data | `mattermost.pvc` | 10 Gi |
| Mattermost Postgres | `mattermost.postgres.pvc` | chart default |
| Quay Postgres and Clair | `quayStorage.quayRegistry.components.*` | `gp3-csi` |
| Quay blobs (SeaweedFS) | `quayStorage.quayRegistry.minio` | 500 Gi |
| RHACS Central database | `acs.central.persistence` | chart default |
| Rosey output | `agentsRoseyRegrets.pvc` | chart default |
| TPA Postgres and S3 | trust-plane `tpa.postgres` / `tpa.minio` | 20 Gi each |
| Tempo | observability `tempo.monolithic.storageClassName` | `gp3-csi` |

## cert-manager

The cert-manager Operator for Red Hat OpenShift is already installed on the target cluster. The chart creates Certificate custom resources and does not add a Subscription or OperatorGroup. A second OperatorGroup fails the CSV with `TooManyOperatorGroups`. Leave the existing Subscription in place.

`05-apply-platform-prep.sh` does not install cert-manager.

## Namespaces

| Namespace | Role |
| --- | --- |
| `test-range` | Optional shadow Deployments, then approved Agent Sandboxes |
| `acs-investigator` | Gemma investigator |
| `acs-agent-builder` | Agentic builder, BuildConfigs, and ImageStreams |
| `acs-maas` | Granite MaaS gateway |
| `monitoring` | Mattermost and the ACS webhook bridge |
| `quay` | Optional on-cluster registry and its SeaweedFS S3 store |
| `stackrox` | ACS Central |
| `trusted-profile-analyzer` | TPA operator, TPA Postgres, and the SBOM S3 store |
| `keycloak` | Red Hat build of Keycloak for the TPA realm |
| `zero-trust-workload-identity-manager` | ZTWIM and SPIRE |
| `agent-sandbox-system` | Agent Sandbox operator |
| `openshift-sandboxed-containers-operator` | Kata, only after `enable-kata.sh` |
| `acs-ai-overwatch-system` | Cluster discovery ConfigMap |
| `acs-ai-overwatch-observability` | OTEL collector, Tempo, MLflow, Grafana |
| `openshift-gitops` | Argo CD |
| `redhat-ods-operator` | OpenShift AI operator |

NetworkPolicies keep the shadow Deployments off MaaS. Approved Sandboxes (`acs-ai-overwatch.io/approved=true`) and the investigator can reach the gateway.

## Images the cluster must be able to pull

| Registry | Used for |
| --- | --- |
| `registry.redhat.io/rhelai1/*` | Gemma and Granite ModelCar images, via the cluster pull secret |
| `docker.io/chrislusf/seaweedfs` | S3 store for Quay and Trusted Profile Analyzer |
| Hugging Face Hub | Rogue MiniCPM GGUF only (`tinyopsec/Huihui-MiniCPM5-2B-abliterated-GGUF`), pulled by the shadow agent pods |
| Internal image registry | Agent ImageStreams in `acs-agent-builder` |

`quay.io/minio/minio` is not anonymously pullable. The charts use SeaweedFS and keep the Service names `quay-minio` and `rhtpa-minio`. How that store is wired is in [Demo setup](demo-setup.md).

## What to do next

Install OpenShift AI 3.5 on this cluster before expecting `default-dsc`: [Red Hat OpenShift AI setup for a clean build](redhat-openshift-ai.md).
