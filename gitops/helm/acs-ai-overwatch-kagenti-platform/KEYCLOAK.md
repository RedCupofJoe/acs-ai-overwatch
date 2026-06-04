# Keycloak authentication for Kagenti (Phase 4)

The Phase 4 install Job (`setup-kagenti.sh` via `kagenti-deps` + `kagenti` Helm charts) **provisions Keycloak and wires OIDC for the Kagenti UI**. You do not install or configure Keycloak manually unless you need custom users, realms, or clients.

## What is configured automatically

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Red Hat Build of Keycloak (RHBK) operator + instance | `keycloak` | Identity provider |
| Realm import Job | `keycloak` | Creates realm **`kagenti`** with demo users |
| OAuth secret Job | `kagenti-system` | Creates `kagenti-ui-oauth-secret` (client `kagenti`, redirect URI, endpoints) |
| Routes | `kagenti-system`, `keycloak` | Public URLs for UI, API, and Keycloak login |

PoC defaults (see `values.yaml`):

```yaml
kagenti:
  keycloakNamespace: keycloak
  keycloakRealm: kagenti
```

The UI and backend run with **`ENABLE_AUTH=true`**. Opening the Kagenti UI redirects to Keycloak; after login you return to the UI with an OpenID token.

## Before install — values to review

Only change these if your cluster uses different namespace or realm names:

| Value | Default | Notes |
|-------|---------|-------|
| `kagenti.keycloakNamespace` | `keycloak` | Must match where RHBK runs |
| `kagenti.keycloakRealm` | `kagenti` | Realm imported by `kagenti-deps` |
| `kagenti.agentNamespaces` | `test-range` | Agent workload namespaces (not Keycloak users) |

Commit and sync Phase 4 per [README — Phase 4](../../../README.md#phase-4--kagenti-platform-opt-in-off-by-default).

## After install — verification checklist

Run from a machine with `oc` logged in as a user who can read secrets in `keycloak` and `kagenti-system`.

**1. Platform install finished**

```bash
helm list -n kagenti-system
# Expect: kagenti-deps and kagenti both deployed

oc get pods -n kagenti-system -l 'app.kubernetes.io/name in (kagenti,kagenti-backend,kagenti-ui)'
# Expect: backend, ui, controller-manager Ready (1/1)
```

**2. Keycloak is running**

```bash
oc get pods -n keycloak
# Expect: keycloak-0 Running, kagenti-realm-import Complete
```

**3. Realm and OAuth client exist**

```bash
oc get secret kagenti-ui-oauth-secret -n kagenti-system
# Expect: secret present; keys AUTH_ENDPOINT, CLIENT_ID, REDIRECT_URI, ENABLE_AUTH

oc get route keycloak -n keycloak -o jsonpath='https://{.spec.host}{"\n"}'
oc get route kagenti-ui -n kagenti-system -o jsonpath='https://{.spec.host}{"\n"}'
```

**4. Print URLs and demo credentials (helper script)**

```bash
./scripts/kagenti-auth-info.sh
```

**5. Browser login test**

1. Open the **Kagenti UI** route (from step 3 or the script).
2. You should be redirected to Keycloak (`/realms/kagenti/...`).
3. Sign in as **`admin`** using the password from `kagenti-test-user` (see below).
4. You should land back on the Kagenti UI, authenticated.

## Demo users (realm `kagenti`)

These users are created by the realm import; passwords are stored in cluster Secrets:

| Username | Typical use | Password secret |
|----------|-------------|-----------------|
| `admin` | Platform / UI admin | `kagenti-test-user` (username + password keys) |
| `dev-user` | Developer | `kagenti-test-users` → `dev-user-password` |
| `ns-admin` | Namespace admin | `kagenti-test-users` → `ns-admin-password` |

Retrieve credentials:

```bash
# Primary UI login (admin)
oc get secret kagenti-test-user -n keycloak \
  -o jsonpath='user={.data.username}{"\n"}pass={.data.password}{"\n"}' \
  | while IFS= read -r line; do
      echo -n "${line%%=*}="
      echo "${line#*=}" | base64 -d
      echo
    done

# All demo user passwords
oc get secret kagenti-test-users -n keycloak \
  -o jsonpath='admin={.data.admin-password}{"\n"}dev-user={.data.dev-user-password}{"\n"}ns-admin={.data.ns-admin-password}{"\n"}' \
  | while IFS= read -r line; do
      echo -n "${line%%=*}="
      echo "${line#*=}" | base64 -d
      echo
    done
```

## Keycloak admin console (optional)

To add users, clients, or realms in the UI — use the **master** realm admin (not the `kagenti` demo `admin` user):

```bash
oc get secret keycloak-initial-admin -n keycloak \
  -o jsonpath='user={.data.username}{"\n"}pass={.data.password}{"\n"}' \
  | while IFS= read -r line; do
      echo -n "${line%%=*}="
      echo "${line#*=}" | base64 -d
      echo
    done
```

Console URL: `https://<keycloak-route>/admin/` (select realm **`kagenti`** in the drop-down after login).

## Optional customization

**Add a user (no Git change)**  
Keycloak admin console → realm **`kagenti`** → Users → Add user → set password on Credentials tab.

**Change realm name**  
Update `kagenti.keycloakRealm` in `values.yaml`, re-run the Phase 4 install (or upstream `setup-kagenti.sh --realm <name>`). Realm import and OAuth jobs must run again.

**Custom Keycloak admin password for the platform**  
During first install, upstream creates `.secrets.yaml` from a template. For GitOps-only flows, use Keycloak admin console or patch Secrets after install.

**Disable UI auth (lab only)**  
Not recommended for this PoC. Upstream supports `--skip-ui` or chart values; agents still expect platform auth in production paths.

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Redirect loop or “invalid redirect URI” | `oc get secret kagenti-ui-oauth-secret -n kagenti-system -o yaml` — `REDIRECT_URI` must match the `kagenti-ui` Route host exactly (`https://.../`). Re-run UI OAuth job if Route changed. |
| Keycloak page 404 | `oc get route keycloak -n keycloak`; wait for `keycloak-0` Ready |
| “Invalid username or password” | Use **`admin`** from `kagenti-test-user`, not `keycloak-initial-admin` (master realm only) |
| UI/backend CrashLoopBackOff | Istio ambient on `kagenti-system` breaks HTTP probes — install script patches `istio.io/dataplane-mode=none` on control-plane Deployments; see [Phase 4 README](../../../README.md#phase-4--kagenti-platform-opt-in-off-by-default) |
| OAuth secret missing | `oc get jobs -n kagenti-system \| grep oauth`; wait for ui-oauth-secret job after `kagenti` Helm release |
| Realm missing | `oc logs job/kagenti-realm-import -n keycloak` — should log `Realm 'kagenti' imported` |

## Agent workloads vs UI login

- **Kagenti UI / API**: Keycloak OIDC users above.
- **Agents in `test-range`**: Registered by the Kagenti operator (SPIFFE / service accounts / AuthBridge) — separate from Keycloak UI users. Enable agent Deployments in the main chart after Phase 4 is healthy (`components.kagenti`).
