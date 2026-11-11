# PoC demo walkthrough (after setup)

Use this after [Demo setup](demo-setup.md) has converged: Mattermost is up, RHACS Central is healthy, the three shadow images exist, and Hank, Rosey, and Sam are running. Apply the trust plane before you terminate and rebuild.

The other guides are [Red Hat OpenShift](redhat-openshift.md), [OpenShift AI](redhat-openshift-ai.md), and [Argo CD GitOps](argocd-gitops.md).

## Health checklist

```bash
oc get application -n openshift-gitops
oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config \
  -o jsonpath='{.data.mattermostSiteUrl}{"\n"}{.data.gitRepoUrl}{"\n"}'
oc get pods -n monitoring -l 'app.kubernetes.io/name in (mattermost,acs-mattermost-bridge)'
oc get pods -n stackrox -l app.kubernetes.io/name=central
oc get securitypolicy -n stackrox test-range-runtime-guardrails
oc get pods -n test-range
oc get imagestream -n acs-agent-builder
oc get llminferenceservice -A
```

| Console | How to open |
| --- | --- |
| Overwatch | `oc get route overwatch-console -n test-range` |
| Mattermost | `mattermostSiteUrl` from the ConfigMap above. Team **ACS**, channel **Town Square**. Log in as `human-in-the-loop` (`mattermost.bootstrap.hitlPassword` in `values.yaml`) |
| RHACS | `oc get route central -n stackrox` |
| Rosey | `oc get route rosey-regrets -n test-range` |

## One agent at a time

Run one script at a time from a machine that is logged in with `oc`. Each script sends that agent’s message, then prints the workload fact that changed: labels, scanner processes, transcripts, the SPIFFE JWT file, or the SecurityPolicy. `AGENT_MESSAGE` overrides the default prompt. `AGENT_URL` overrides the Route.

| Order | Script | What changes on the platform |
| --- | --- | --- |
| 1 | `scripts/demo/agents/helpful-hank.sh` | Chat only. Telemetry stays enabled. No scanner process. |
| 2 | `scripts/demo/agents/rosey-regrets.sh` | Network Audit starts nmap, masscan, rustscan, and naabu. Runtime policy `test-range-runtime-guardrails` records it. The pod keeps running. |
| 3 | `scripts/demo/agents/sneaky-sam.sh` | Sam answers from a Deployment that omits the telemetry label. Deploy policy `test-range-sneaky-sam-telemetry-violation`. |
| 4 | `scripts/demo/agents/compliant-chris.sh` | After the trust plane: Sandbox, SPIFFE JWT, CSV answer, no scanners. |
| 5 | `scripts/demo/agents/remediated-rosey.sh` | After rebuild: the same Network Audit phrase does not start a scanner. |
| 6 | `scripts/demo/agents/remediated-sam.sh` | After rebuild: telemetry and `approved=true` are set, and a SPIFFE JWT is mounted. |

`scripts/trigger-network-audit.sh` runs the Rosey script. `ROSEY_URL` and `NETWORK_AUDIT_COMMAND` still work.

## Demo 1 — Hank, then Rosey, then Sam

Open the Overwatch console beside RHACS and Mattermost so each script lines up with a screen.

```bash
./scripts/demo/agents/helpful-hank.sh
```

Hank answers. Inventory in `test-range` shows a plain Deployment with `acs-ai-overwatch.io/telemetry=enabled`. No recon process starts, and the runtime policy stays quiet. This is the quiet shadow agent.

```bash
./scripts/demo/agents/rosey-regrets.sh
```

Rosey’s reply returns as soon as the audit starts. The script then waits until a scanner process is visible and lists `/agent-reference-information`. In RHACS Central, open Violations for namespace `test-range` and policy `test-range-runtime-guardrails`. Enforcement is none, so the pod keeps running. Town Square shows the same alert. The bridge also POSTs to the investigator.

```bash
oc logs -n monitoring deploy/acs-mattermost-bridge --tail=30
oc logs -n acs-investigator deploy/acs-investigator --tail=50
```

```bash
./scripts/demo/agents/sneaky-sam.sh
```

Sam answers. His Deployment is the row that omits the telemetry label. In RHACS, open policy `test-range-sneaky-sam-telemetry-violation`. Monitor mode leaves the pod running. The finding is the missing label, which is already true when the pod is admitted. The chat shows the audience that the pod is still serving.

## Trust plane, then terminate and rebuild

```bash
oc apply -k gitops/argocd/overlays/demo-trust
./scripts/demo/identify-terminate-rebuild.sh
oc get sandbox -n test-range
```

The rebuild script refuses to run until ZTWIM, TPA, Agent Sandbox, and Keycloak are Ready. Enforce mode kills Rosey and Sam and scales Hank to zero. The builder applies the remediated Sandboxes only after TPA accepts the SBOM.

## Demo 2 — Approved agents

```bash
./scripts/demo/agents/compliant-chris.sh
./scripts/demo/agents/remediated-rosey.sh
./scripts/demo/agents/remediated-sam.sh
```

Chris is available once the approved Application has synced. The two remediated scripts exit until `identify-terminate-rebuild.sh` has created those Sandboxes.

Chris calls `query_career_dataset` or `career_dataset_info` before answering. Try “Placement rate”, “Salary by branch”, or “Lookup S0” by setting `AGENT_MESSAGE`. RHACS should stay quiet for these Sandboxes. Remediated Rosey receives the same “Network Audit” phrase and does not start nmap. Remediated Sam now carries telemetry and `acs-ai-overwatch.io/approved=true`, and the script checks that a SPIFFE JWT file is mounted.

| Agent | What the audience should take away |
| --- | --- |
| Helpful Hank | Local MiniCPM, telemetry on, no recon process |
| Rosey Regrets | MiniCPM plus nmap, masscan, rustscan, and naabu. Runtime violation, pod still up |
| Sneaky Sam | MiniCPM, telemetry label missing. Deploy-time violation, pod still up |
| Remediated Rosey / Sam | OpenClaw inside OpenShell on an Agent Sandbox, TPA-cleared, SPIFFE JWT-SVID |
| Compliant Chris | Same approved shape from the start, plus the placement CSV |
