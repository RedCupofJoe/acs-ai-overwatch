# RHOAI Setup

> **PoC:** GitOps/Helm installs the RHOAI operator and `DataScienceCluster/default-dsc`. Do **not** apply `01-datasciencecluster` (workshop sets `kueue: Unmanaged` and extra Managed components). Optional: `05-apply-platform-prep.sh --with-rhoai-operator` for `00-rhoai-operator` only. OperatorGroup is `redhat-ods-operator` with empty `spec`. See [configs/README.md](../README.md).

Installs and configures Red Hat OpenShift AI: operator, DataScienceCluster, gateways, MaaS, MLflow, and dashboard customization.


## Objectives

- Install RHOAI and enable required components
- Prepare the cluster for data scientist personas (hardware profiles, pipelines, model serving)
- Configure Models-as-a-Service gateway, database, and observability

## Rationale

Installing OpenShift AI is not the last step—workloads need GPU resources advertised, sufficient non-GPU capacity, object storage, and gateway auth before users can work effectively.

## Takeaways

- RHOAI 3.0+ requires OpenShift 4.19+
- DataScienceCluster components can be `Managed`, `Removed`, or `Unmanaged`
- Hardware profiles are required in RHOAI 3.x to assign GPU resources to workbenches and serving runtimes
- If GPU nodes use `nvidia.com/gpu` taints, hardware profiles must include matching tolerations
- Do not install ISV applications in `redhat-ods-*` namespaces

## Documentation

- [Red Hat OpenShift AI Self-Managed 3.4 documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4)
- [Installing and deploying OpenShift AI](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/installing_and_uninstalling_openshift_ai_self-managed/installing-and-deploying-openshift-ai_install)
- [Working with hardware profiles](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/working_with_accelerators/working-with-hardware-profiles_accelerators)

## Setup Steps

### 00 - RHOAI Operator

Installs the Red Hat OpenShift AI operator from OperatorHub.

**Documentation:** [Installing the Red Hat OpenShift AI Operator](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/installing_and_uninstalling_openshift_ai_self-managed/index#installing-the-red-hat-openshift-ai-operator)

```bash
oc apply -k configs/04-rhoai-setup/00-rhoai-operator
```

**Validation:**

```bash
oc get projects | grep -E 'redhat-ods|rhods'
oc describe dscinitialization default-dsci -n redhat-ods-operator
```

Expected projects include `redhat-ods-applications`, `redhat-ods-monitoring`, and `redhat-ods-operator`.

### 01 - DataScienceCluster

Creates the DataScienceCluster instance that enables dashboard, workbenches, KServe, training, and other components.

```bash
oc apply -k configs/04-rhoai-setup/01-datasciencecluster
```

**Validation:**

```bash
oc wait --for=jsonpath='{.status.phase}'=Ready datasciencecluster default-dsc -n redhat-ods-operator --timeout=15m
oc get DataScienceCluster,DSCInitialization -n redhat-ods-operator
```

### 02 - Observability

Configures DSCInitialization monitoring settings and creates the Models as a Service tenant with telemetry enabled.

**Documentation:** [Enabling the observability stack](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/managing_openshift_ai/managing-observability_managing-rhoai#enabling-the-observability-stack), [Collecting metrics from user workloads](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/managing_openshift_ai/managing-observability_managing-rhoai#collecting-metrics-from-user-workloads)

```bash
oc apply -k configs/04-rhoai-setup/02-observability
```

### 03 - Inference Gateway

Creates the OpenShift AI inference Gateway used to route traffic to model-serving workloads.

**Documentation:** [Configuring your model-serving platform](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/configuring_your_model-serving_platform/index)

```bash
oc apply -k configs/04-rhoai-setup/03-inference-gateway
```

### 04 - MaaS Gateway

Creates the Models as a Service gateway, route, and TLS configuration for authenticated model access.

**Documentation:** [Deploy and manage Models-as-a-Service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas), [MaaS Namespace Security Knowledge Base](https://access.redhat.com/solutions/7145755)

```bash
oc apply -k configs/04-rhoai-setup/04-maas-gateway
```

**TLS:** The Route uses **passthrough** termination. The hostname job sets both the Route host and `spec.listeners[].hostname` on the Gateway (required for `maas-api` URL discovery). The Gateway terminates TLS with the cluster ingress wildcard certificate (`cert-manager-ingress-cert` in `openshift-ingress`), so `curl` works without `-k` on OpenTLC clusters.

**Prerequisite:** `cert-manager-ingress-cert` must exist in `openshift-ingress` (provisioned by the cluster cert-manager setup). Verify with:

```bash
oc get secret cert-manager-ingress-cert -n openshift-ingress
```

**Validation:**

```bash
ROUTE_HOST=$(oc get route maas-gateway-route -n openshift-ingress -o jsonpath='{.spec.host}')
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  "https://${ROUTE_HOST}/v1/models"
# Expected: 200
```

**Troubleshooting "maas-api is not available":** Confirm the hostname job completed and the Gateway listener has a hostname:

```bash
oc get jobs job-patch-route-host -n openshift-ingress
oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[0].hostname}{"\n"}'
oc logs -n redhat-ods-applications deploy/maas-ui --tail=10
```

### 05 - Namespace Gateway Access

Labels namespaces with `maas-gateway-access` so HTTPRoutes can attach to the MaaS gateway.

```bash
oc apply -k configs/04-rhoai-setup/05-namespace-gateway-access
```

### 06 - MaaS Database

Deploys a PostgreSQL database used by Models as a Service.

**Documentation:** [Govern LLM access with Models-as-a-Service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index)

```bash
oc apply -k configs/04-rhoai-setup/06-maas-database
```

### 07 - MaaS Connection

Creates the database connection secret that links Models as a Service to the PostgreSQL database.

**Documentation:** [Deploy and manage Models-as-a-Service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas)

```bash
oc apply -k configs/04-rhoai-setup/07-maas-connection
```

### 08 - Restart Kuadrant

Restarts Kuadrant operators so AuthPolicies are accepted after the gateway and MaaS connection are ready. Required for MaaS API authentication (for example, the dashboard tokens page).

```bash
./configs/04-rhoai-setup/08-restart-kuadrant/restart-kuadrant.sh
```

**Validation:**

```bash
oc get authpolicy -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,ACCEPTED:.status.conditions[?(@.type=="Accepted")].status'
```

AuthPolicies should show `Accepted=True`.

### 09 - MLflow

Deploys an MLflow instance for experiment tracking and model artifacts.

**Documentation:** [Install and configure MLflow](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/working_with_mlflow/installing-mlflow_mlflow)

```bash
oc apply -k configs/04-rhoai-setup/09-mlflow
```

### 10 - Hardware Profiles

Creates NVIDIA GPU hardware profiles for model serving and workbench workloads, including `nvidia.com/gpu` tolerations when GPU nodes are tainted.

**Objectives:** Assign accelerator resources through RHOAI hardware profiles so the dashboard can schedule GPU workbenches and serving runtimes.

**Documentation:** [Working with hardware profiles](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/working_with_accelerators/working-with-hardware-profiles_accelerators)

```bash
oc apply -k configs/04-rhoai-setup/10-hardware-profiles
```


**Validation:**

```bash
oc get nodes -l nvidia.com/gpu.machine -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
oc get hardwareprofile -n redhat-ods-applications
```

### 11 - Dashboard Customization

Customizes the OpenShift AI dashboard, including Gen AI Studio, observability, and available serving runtime templates.

**Documentation:** [Enable the observability dashboard in the UI](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/managing_openshift_ai/managing-observability_managing-rhoai#enable-the-observability-dashboard-in-the-ui), [Administer OpenShift AI platform access, apps, and operations](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/managing_openshift_ai/index)

```bash
oc apply -k configs/04-rhoai-setup/11-dashboard-customization
```

## Additional Steps

- Verify GPU nodes show allocatable `nvidia.com/gpu` before creating workbenches
- Review MaaS gateway host URL and namespace admission labels
- The `dev` user should be able to create a GPU workbench after hardware profiles are applied
