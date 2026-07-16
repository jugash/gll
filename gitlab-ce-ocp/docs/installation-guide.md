# Installation & Operations Guide — gitlab-ce-ocp

Step-by-step to deploy, upgrade, back up, and restore GitLab CE on OpenShift using this
chart.

---

## 1. Prerequisites

- OpenShift 4.12+ cluster and `oc` logged in.
- **`cluster-admin`** for the install (the chart creates a cluster-scoped SCC — required
  by any GitLab-on-OpenShift install).
- **Helm 3.8+**.
- A default (or named) **StorageClass** providing **RWO block** volumes (e.g. ODF Ceph
  RBD, cloud block). Confirm: `oc get storageclass`.
- **DNS**: a hostname pointing at your OCP apps wildcard/router, e.g.
  `gitlab.apps.ocp.example.com`.
- Node headroom: at least **8 vCPU / 16 GB** schedulable for the GitLab pod.

---

## 2. Quick start (Phase 1 — bundled, self-contained)

```bash
# 1. Create the project/namespace
oc new-project gitlab

# 2. Review and edit values (at minimum: externalUrl + route.host + storageClass)
#    Both must match your DNS record.
$EDITOR chart/values.yaml

# 3. Install
helm install gitlab ./chart \
  --namespace gitlab \
  --set gitlab.externalUrl=https://gitlab.apps.ocp.example.com \
  --set openshift.route.host=gitlab.apps.ocp.example.com

# 4. Watch it come up (first boot = 5–15 min for migrations + reconfigure)
oc rollout status statefulset/gitlab-gitlab-ce -n gitlab
oc logs -f gitlab-gitlab-ce-0 -n gitlab
```

### First login
```bash
# If you didn't set a root password, read the auto-generated one (valid 24h):
oc exec -it gitlab-gitlab-ce-0 -n gitlab -- cat /etc/gitlab/initial_root_password
```
Browse to your `externalUrl`, sign in as `root`, and **change the password immediately**.

### Git over SSH
The chart creates a separate `*-ssh` Service (SSH can't go through the HTTP Router). For
external access set `service.ssh.type=LoadBalancer` (cloud) or `NodePort`, then point
clients at that address on port 22 (or your NodePort).

---

## 3. Phase 2 — external HA datastores (recommended production posture)

Provision HA datastores first (out of scope for this chart), then create the secrets and
install with the HA values file.

```bash
# Secrets the chart expects (names are configurable in values):
oc create secret generic gitlab-postgres   --from-literal=password='<db-pass>'      -n gitlab
oc create secret generic gitlab-redis       --from-literal=password='<redis-pass>'   -n gitlab
oc create secret generic gitlab-objectstore --from-literal=accesskey='<key>' \
                                             --from-literal=secretkey='<secret>'      -n gitlab

# Edit endpoints/hosts to match your Postgres operator, Redis Sentinel, and ODF/S3
$EDITOR chart/values-production-ha.yaml

helm upgrade --install gitlab ./chart \
  --namespace gitlab \
  -f chart/values-production-ha.yaml
```

Recommended backing services on OCP:
- **PostgreSQL:** CloudNativePG or Crunchy Postgres Operator (primary + 2 replicas, auto-failover).
- **Redis:** Redis Sentinel (3 sentinels).
- **Object storage:** OpenShift Data Foundation (NooBaa/RGW) or external S3, with the
  buckets named in the values file pre-created.

Migration note: moving from bundled to external Postgres/Redis is a data migration
(`gitlab-backup` restore into the new DB, or `pg_dump`/`pg_restore`). Plan a maintenance
window; don't just flip the flags on an installation that already has data without
migrating it.

---

## 4. Common configuration

| Need | Where |
|---|---|
| SMTP / email | `gitlab.extraOmnibusConfig` (raw `gitlab.rb`) |
| LDAP / SAML | `gitlab.extraOmnibusConfig` |
| TLS mode | `openshift.route.tls.termination` (`edge`/`reencrypt`/`passthrough`) |
| Custom cert | `openshift.route.tls.certificate` / `.key` / `.caCertificate` |
| Storage sizes | `persistence.data|config|logs.size` |
| CPU/memory | `resources.requests` / `resources.limits` |
| Root password | `gitlab.rootPassword.value` or `.existingSecret` |
| Non-OCP cluster | set `openshift.route.enabled=false`, `openshift.ingress.enabled=true` |

After changing config, `helm upgrade` re-renders the ConfigMap; the checksum annotation
rolls the pod so Omnibus re-runs `reconfigure`.

---

## 5. Upgrades

GitLab requires **sequential** upgrades across some major/minor versions — do **not**
jump multiple minors at once. Check GitLab's upgrade path for your source→target
versions first.

```bash
# 1. Take a fresh backup (see §6) and snapshot PVCs if your storage supports it.
# 2. Bump the image tag
helm upgrade gitlab ./chart -n gitlab --set image.tag=18.9.0-ce.0 --reuse-values
# 3. Watch migrations
oc logs -f gitlab-gitlab-ce-0 -n gitlab
```

Because this is a single pod, the upgrade incurs a brief outage while the new pod boots
and migrates. This is expected for Phase 1/2.

---

## 6. Backup & restore

### Automated
Enabled by default: a **CronJob** (`gitlab-backup`, nightly 02:00) that `oc exec`s into
the pod, runs `gitlab-backup create`, and separately tars `/etc/gitlab` (which holds
`gitlab-secrets.json` — **required** to restore, and not part of the app backup).

Run one on demand:
```bash
oc create job --from=cronjob/gitlab-gitlab-ce-backup manual-$(date +%s) -n gitlab
```
With `externalServices.objectStorage` + a `backups` bucket set, app backups stream to S3.

### Manual backup
```bash
oc exec -it gitlab-gitlab-ce-0 -n gitlab -- gitlab-backup create
oc exec -it gitlab-gitlab-ce-0 -n gitlab -- \
  tar czf /var/opt/gitlab/backups/etc-gitlab.tar.gz -C /etc/gitlab .
# Copy off-cluster
oc cp gitlab/gitlab-gitlab-ce-0:/var/opt/gitlab/backups ./gitlab-backups
```

### Restore
```bash
# Place the backup tar in /var/opt/gitlab/backups and restore etc/ first
oc exec -it gitlab-gitlab-ce-0 -n gitlab -- gitlab-ctl stop puma
oc exec -it gitlab-gitlab-ce-0 -n gitlab -- gitlab-ctl stop sidekiq
oc exec -it gitlab-gitlab-ce-0 -n gitlab -- \
  gitlab-backup restore BACKUP=<timestamp_version>
oc exec -it gitlab-gitlab-ce-0 -n gitlab -- gitlab-ctl reconfigure
oc exec -it gitlab-gitlab-ce-0 -n gitlab -- gitlab-ctl restart
oc exec -it gitlab-gitlab-ce-0 -n gitlab -- gitlab-rake gitlab:check SANITIZE=true
```
**Restore fails without the matching `gitlab-secrets.json`** — always restore `/etc/gitlab`
alongside the app backup.

---

## 7. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod `CrashLoopBackOff` immediately | SCC not applied (running as random UID) | Confirm SCC + RoleBinding exist; `oc get scc \| grep gitlab`; installed as cluster-admin? |
| Pod restarts every few minutes during first boot | Liveness probe too aggressive vs migrations | Ensure `probes.startup.enabled=true`; raise `failureThreshold` |
| 502 from the Route | GitLab still booting, or double-TLS | Wait for readiness; check `route.tls.termination` matches Omnibus HTTP-only config |
| Redirect loop / mixed content | `external_url` scheme vs Route termination mismatch | Use `https://` externalUrl with `edge`; chart sets `X-Forwarded-Proto` |
| Git push over SSH fails | SSH not exposed (Router is HTTP only) | Set `service.ssh.type=LoadBalancer/NodePort` |
| PVC `Pending` | No matching StorageClass / RWO | Set `persistence.*.storageClass`; check `oc get sc` |
| Backup CronJob `Forbidden` on exec | Missing RBAC | Chart ships a Role for pods/exec; confirm it applied |

Health endpoints: `GET /-/health`, `/-/readiness`, `/-/liveness`.
Logs: `oc exec gitlab-gitlab-ce-0 -n gitlab -- gitlab-ctl tail`.

---

## 8. Uninstall

```bash
helm uninstall gitlab -n gitlab
# PVCs from a StatefulSet are retained by design — delete explicitly if intended:
oc delete pvc -l app.kubernetes.io/instance=gitlab -n gitlab
# SCC is cluster-scoped; helm removes it, but verify:
oc get scc | grep gitlab-ce
```
