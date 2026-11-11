# Argo CD GitOps setup and troubleshooting

How this repository is registered with OpenShift GitOps, and how to repair a sync that stalls. Install order for the demo is in [Demo setup](demo-setup.md). Cluster prerequisites are in [Red Hat OpenShift](redhat-openshift.md) and [OpenShift AI](redhat-openshift-ai.md).

## Before the first sync

`./scripts/cluster-admin/install-pre-gitops.sh` runs, in order:

| Step | What it does |
| --- | --- |
| 0 | AppProject `acs-ai-overwatch` |
| 1 | ClusterRoleBinding so the application controller can create cluster-scoped objects such as `SecurityContextConstraints` and Central. Skip with `--skip-rbac` only when managed-by namespaces are enough |
| 2 | Raises `ArgoCD/openshift-gitops` controller memory to a limit of 8 Gi (request 2 Gi). The 2 Gi default is OOMKilled (exit 137) while comparing this chart, and the sync stays `Running` |
| 3 | Grants Argo CD UI admin to the sandbox SSO user `admin`. That user is cluster-admin through a binding, and is not in the `cluster-admins` group. Dex forwards groups only, unless the scopes include `preferred_username` and `email`. Without this grant the UI loads and then shows permission denied |
| 4 | Treats a `Pending` PersistentVolumeClaim as Healthy. `gp3-csi` waits for a consumer pod, and that pod is a later sync wave. A strict PVC health check blocks Central and every later wave |
| 5 | Labeled PoC namespaces |
| 6 | ConfigMap `acs-ai-overwatch-cluster-config` |
| 7 | Discovery ServiceAccount and script ConfigMap |

`--with-values-file` also runs `discover-cluster-values.sh`. `--skip-discovery-prereqs` leaves the discovery ServiceAccount for Argo CD to create.

Individual scripts live in `scripts/cluster-admin/` and are listed in `scripts/cluster-admin/README.md`.

On a fork, set `spec.source.repoURL` in every `gitops/argocd/application*.yaml` before `oc apply`.

## Applications

Sync-wave annotations on the Application objects do not make separate Argo apps wait for each other. Apply the kustomizations in the order in [Demo setup](demo-setup.md).

| Application | Delivers | Path A `gitops/argocd/` | Path B `demo-wrong` | Path B later `demo-trust` |
| --- | --- | --- | --- | --- |
| `acs-ai-overwatch-gitops-bootstrap` | Namespaces, including trust-plane namespaces, labeled `argocd.argoproj.io/managed-by` | yes | yes | already present |
| `acs-ai-overwatch-cluster-discovery` | ConfigMap `acs-ai-overwatch-cluster-config` | yes | yes | already present |
| `acs-ai-overwatch` | Operators, Mattermost, ACS, MaaS, builder, console, Quay, BuildConfigs | yes | yes | already present |
| `acs-ai-overwatch-observability` | OTEL collector, Tempo, MLflow, Grafana | yes | yes | already present |
| `acs-ai-overwatch-misbehavior` | Hank, Rosey, Sam, and monitor-mode policies | | yes | leave it installed |
| `acs-ai-overwatch-trust-plane` | TPA, Keycloak, ZTWIM, Agent Sandbox. Kata only when enabled | yes | | yes |
| `acs-ai-overwatch-approved` | Compliant Chris. Enforce-mode policies on Path A. Path B sets `securityPolicies.enabled=false` so this app does not fight the misbehavior policies | yes | | yes |

`gitops/argocd/kustomization.yaml` is Path A: platform, observability, trust plane, and approved sandboxes. `overlays/demo-wrong` is the shadow phase. `overlays/demo-trust` adds the operators and Compliant Chris onto a cluster that already has the platform.

### Converged

| Check | Command |
| --- | --- |
| Argo apps | `oc get application -n openshift-gitops` |
| Cluster ConfigMap | `oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config` |
| Mattermost | `oc get pods -n monitoring -l app.kubernetes.io/name=mattermost` |
| RHACS Central | `oc get central -n stackrox` |
| TPA operator | `oc get csv -n trusted-profile-analyzer -o custom-columns=NAME:.metadata.name,PHASE:.status.phase` |
| Observability | `oc get deploy -n acs-ai-overwatch-observability acs-otel-collector` |
| Image tags | `oc get imagestream -n acs-agent-builder` |

`values.yaml` defaults `platformResources.waitForCrds` to `true`, which omits CRD-gated objects until Helm `lookup` sees the CRD. `values-poc.yaml` sets `waitForCrds: false`, so the PoC sync renders DataScienceCluster, QuayRegistry, Tekton Tasks, and Central immediately. The first sync can fail those objects until the operators finish. Refresh the Application after the CSVs are `Succeeded`.

```bash
oc annotate application acs-ai-overwatch -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

## Cluster settings

The main Application merges, in order:

| File | Role |
| --- | --- |
| `values.yaml` | Defaults. Mattermost host and Quay server are empty here so a discovered value can fill them |
| `values-poc.yaml` | PoC toggles, including `waitForCrds: false` and Quay enabled |
| `values-cluster.yaml` | One cluster’s apps domain, Mattermost URL, Quay hostname, StorageClass, and operator channels |

`gitops/argocd/overlays/demo-wrong/platform/application.yaml` lists all three, with `ignoreMissingValueFiles: true`.

The discovery Application writes the same facts to `acs-ai-overwatch-system/acs-ai-overwatch-cluster-config`. Helm templates prefer that ConfigMap for the Mattermost host when `lookup` can read it. This OpenShift GitOps release’s Application CRD does not accept `spec.source.helm.serverDryRun`, so repo-server `lookup` often does not see the ConfigMap. The committed `values-cluster.yaml` is then the hostname Argo CD applies.

Regenerate it on every new cluster and commit the result when this repository is what Argo CD tracks:

```bash
make cluster-values
# or: ./scripts/discover-cluster-values.sh
```

| Field | Source |
| --- | --- |
| `cluster.appsDomain` | `ingresses.config.openshift.io/cluster` |
| `cluster.name` | Infrastructure CR or the current context |
| `mattermost.siteUrl` and `mattermost.route.host` | `mattermost-<namespace>.<appsDomain>` |
| `storage.defaultStorageClass` | Default StorageClass, else `gp3-csi` |
| `quayStorage.quayOperator.subscription.channel` | Latest `stable-3.*` from the `quay-operator` packagemanifest |
| `quayStorage.registryCredentials.server` | Quay Route if it exists, else `quay-quay.<appsDomain>` |
| `rhoai.operator.subscription.channel` | `stable-3.5` / `fast-3.5` / `eus-3.5` |
| `acs.operator.subscription.channel` | `rhacs-operator` default channel |
| `accelerators.*.subscription.channel` | `nfd` and `gpu-operator-certified` default channels |
| `agents.gitRepoUrl` / `pipelines.gitUrl` | `git remote origin` |

`QUAY_REGISTRY_PASSWORD`, when set in the environment, is written into that file. Leave it unset for a commit. A previous sandbox’s `appsDomain` makes the Mattermost Route resolve as `DNS_PROBE_FINISHED_NXDOMAIN`.

If Helm `lookup` is required and the repo-server cannot see the cluster, use the optional plugin in `gitops/argocd/cmp/`.

Still set by hand:

| Setting | Where |
| --- | --- |
| Quay robot password | `quayStorage.registryCredentials.password` or `QUAY_REGISTRY_PASSWORD` |
| Mattermost bootstrap passwords | `mattermost.bootstrap.adminPassword` and `hitlPassword` in `values.yaml` |
| Fork URL | `spec.source.repoURL` on every Application |
| SeaweedFS secret | `quayStorage.quayRegistry.minio.credentialsSecret.secretKey` |

## Argo CD UI

Route `openshift-gitops-server` in `openshift-gitops`. The HTML page can return HTTP 200 while every list call is permission denied. `install-pre-gitops.sh` adds `g, admin, role:admin` and sets scopes to `[groups, preferred_username, email]`. Log out and back in after that patch so the token is reissued.

## Local render

```bash
helm template acs-ai-overwatch gitops/helm/acs-ai-overwatch \
  -f gitops/helm/acs-ai-overwatch/values.yaml \
  -f gitops/helm/acs-ai-overwatch/values-poc.yaml \
  -f gitops/helm/acs-ai-overwatch/values-cluster.yaml \
  --set platformResources.waitForCrds=false

helm template trust gitops/helm/acs-ai-overwatch-trust-plane \
  --set cluster.appsDomain=apps.lab.example.com \
  --set platformResources.waitForCrds=false

helm template approved gitops/helm/acs-ai-overwatch-approved \
  --set platformResources.waitForCrds=false
```

`make helm-template` renders the main chart with the same three values files when `values-cluster.yaml` is present.

## Troubleshooting

### Application controller OOM, sync stuck in Running

`openshift-gitops-application-controller-0` at a 2 Gi limit exits 137 and CrashLoops. The restarted controller resumes the same operation, so auto-sync says another operation is in progress. `install-pre-gitops.sh` sets the limit to 8 Gi on the `ArgoCD` custom resource (`spec.controller.resources`). Patch the CR, not only the StatefulSet. The operator owns the pod spec.

### Sync waits forever on a Pending PVC

`gp3-csi` is `WaitForFirstConsumer`. The pod that binds the claim is a later wave, so the claim stays `Pending` and Argo never starts that wave. `spec.resourceHealthChecks` on the `ArgoCD` CR marks `Pending` and `Bound` as Healthy. The annotation `argocd.argoproj.io/ignore-healthcheck` on the claim does not release the wave.

### Argo CD UI permission denied

The route itself returns HTTP 200. User `admin` has no groups, and the default RBAC only maps `system:cluster-admins` and `cluster-admins`. Add `g, admin, role:admin` and scopes `[groups, preferred_username, email]` on `spec.rbac`, then log in again.

### Controller cannot create SCCs or Central

Apply `gitops/argocd/bootstrap/openshift-gitops-controller-rbac.yaml` (included in `install-pre-gitops.sh`). This must print `yes`:

```bash
oc auth can-i create securitycontextconstraints \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
```

### `ErrImagePull` / `manifest unknown`

The ImageStream exists and has no tags. The BuildConfig was created with an empty trigger list, or it already existed so `ConfigChange` did not run. `oc start-build <name> -n acs-agent-builder` from Git, or `--from-dir=.` from a dirty tree. Delete the pod after the push so it does not sit in `ImagePullBackOff`. Image build details are in [Demo setup](demo-setup.md).

### Trusted Profile Analyzer `ResolutionFailed` or `UnsupportedOperatorGroup`

The catalog channel is `stable-v3`. A channel named `stable` is not published, so the Subscription stays `ResolutionFailed`. If the CSV is `Failed` with `AllNamespaces InstallModeType not supported`, set the OperatorGroup `targetNamespaces` to `trusted-profile-analyzer` and let the CSV install again. Both fixes are in the trust-plane chart. See [Demo setup](demo-setup.md).

### Mattermost `NXDOMAIN`

The Route `spec.host` is a previous cluster’s apps domain. `values-cluster.yaml` still has that domain, and Helm lookup did not override it. Put this cluster’s `appsDomain` in that file, refresh the Application, restart `deploy/mattermost`, and point `mattermost-acs-integration` at the new host plus the existing `/hooks/<token>` path. Restart `acs-mattermost-bridge`.

### Quay or TPA S3 `ImagePullBackOff` on `quay.io/minio/minio`

That image is not anonymously pullable. The charts run SeaweedFS and keep the Service name `quay-minio` or `rhtpa-minio`. If Argo still has the MinIO image, the Git revision Argo is syncing predates the SeaweedFS commit.

### Pipelines or Quay `ConstraintsNotSatisfiable`

Two Subscriptions for `openshift-pipelines-operator-rh` (one from the console, one from the chart) leave an unreferenced CSV. Delete the console Subscription, then the unreferenced CSV, and let the chart Subscription own the install.

### Tekton `no matches for kind Task`

`values-poc.yaml` sets `waitForCrds: false`, so Tasks render in an earlier wave than the Pipelines Subscription. Wait until the Pipelines CSV is `Succeeded` and the CRDs `tasks.tekton.dev` and `pipelines.tekton.dev` are `Established`, then refresh.

### Build `FailedMount` for `*-ca` ConfigMaps

Transient. The build pod was scheduled before the build controller created `<build>-ca`, `<build>-global-ca`, and `<build>-sys-config`. The container still starts. A real failure is later in the build log (`DockerBuildFailed`).

### Agent chat fails

`LLM_API_BASE` must be set. Approved agents fall back to `LLM_API_KEY` when `/run/spiffe-svid/jwt_svid.token` is missing. If the SPIFFE Helper init container is stuck, the SPIRE agent socket is not mounted or the pod is missing `acs-ai-overwatch.io/approved=true`, so no SVID is issued.

OpenShift AI CSV and DataScienceCluster failures are in the [OpenShift AI guide](redhat-openshift-ai.md).
