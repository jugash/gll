# Installation & Operations — Operator variation

Deploy GitLab CE on OpenShift via the GitLab Operator with in-cluster datastores:
**CloudNativePG** (PostgreSQL), **Valkey** (Redis), and **MinIO** (object storage).

> **Image/license note.** These replace the previously-common Bitnami images, whose
> public catalog was deleted on 2025-09-29 (versioned tags moved to the unmaintained
> `bitnamilegacy` repo; hardened images are now paid Bitnami Secure Images). The stack
> here is license-clean and actively maintained: CloudNativePG (Apache-2.0), Valkey
> (BSD-3), MinIO (AGPL-3.0). For production object storage, prefer OpenShift Data
> Foundation over MinIO.

---

## 1. Prerequisites

- OpenShift 4.12+, `oc` logged in as **cluster-admin** (required to install operators).
- **The CloudNativePG operator installed** (OperatorHub → "CloudNativePG") — Postgres is
  deployed as a CNPG `Cluster`. One-time cluster install.
- **Helm 3.8+** (for the deps-chart).
- A **RWO block StorageClass** (e.g. ODF Ceph RBD). Check: `oc get storageclass`.
- DNS: an apps wildcard/host pointing at your OCP router, e.g. `*.apps.ocp.example.com`.
- Node capacity: the microservice tier + datastores need materially more than the Omnibus
  variation — budget ~12–16 vCPU / 24–32 GB across nodes for a team-scale HA install.

---

## 2. Install the GitLab Operator (OLM)

> GitLab documents the OLM install as **experimental**. Use **manual** approval and pin
> versions. See https://docs.gitlab.com/operator/installation/ for the current manifests.

```bash
# Create the operator namespace
oc new-project gitlab-system

# Apply the release manifest matching your platform/RBAC scope from the Operator
# releases page (pick the OpenShift/OLM one). Example shape:
#   oc apply -f https://gitlab.com/gitlab-org/cloud-native/gitlab-operator/-/releases/<ver>/downloads/gitlab-operator-openshift.yaml

# Verify the operator is running
oc get pods -n gitlab-system
oc get csv -n gitlab-system            # if installed via OperatorHub/OLM
```

Set the Subscription's `installPlanApproval: Manual` if you installed via OperatorHub, so
GitLab upgrades don't happen automatically.

---

## 3. Deploy in-cluster dependencies

```bash
oc new-project gitlab

# Optional: set your storage class and passwords first
#   $EDITOR deps-chart/values.yaml   (global.storageClass, postgresql/redis/minio)

helm install deps ./deps-chart -n gitlab

# Wait for datastores
oc get pods -n gitlab -l app.kubernetes.io/part-of=gitlab-deps -w
```

This creates:
- Services `gitlab-postgresql-rw:5432` (CNPG), `gitlab-redis:6379` (Valkey), `gitlab-minio:9000`
- Secrets `gitlab-postgresql`, `gitlab-redis`, `gitlab-objectstore`, `gitlab-rails-storage`
- MinIO buckets: artifacts, lfs, uploads, packages, registry, backups

Passwords are auto-generated if left blank. Read them with:
```bash
oc get secret gitlab-postgresql -n gitlab -o jsonpath='{.data.password}' | base64 -d; echo
```

---

## 4. Apply the GitLab custom resource

```bash
# Edit domain, host, and the chart version your Operator supports
$EDITOR gitlab-cr.yaml

# Dry-run first
oc apply --dry-run=server -f gitlab-cr.yaml -n gitlab

oc apply -f gitlab-cr.yaml -n gitlab
oc get gitlab -n gitlab -w
```

Finding a supported chart version:
```bash
# The Operator supports a range of chart versions; check its docs/release notes.
# global.edition=ce selects Community Edition images automatically.
```

First reconcile runs migrations and can take 10–20 minutes. Watch:
```bash
oc get pods -n gitlab
oc logs deploy/gitlab-webservice-default -n gitlab
```

Get the initial root password (Operator/chart creates a secret):
```bash
oc get secret gitlab-gitlab-initial-root-password -n gitlab \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

---

## 5. Upgrading to in-cluster HA datastores

### PostgreSQL → 3-node CloudNativePG
Postgres is already CNPG; scaling to HA is just more instances (rolling, no data migration):
```bash
helm upgrade deps ./deps-chart -n gitlab --reuse-values \
  --set postgresql.instances=3
```
CNPG adds replicas with streaming replication and automatic failover behind the same
`gitlab-postgresql-rw` service — the GitLab CR needs no change.

### Redis/Valkey → Sentinel HA
Deploy HA Valkey with a purpose-built Redis/Valkey operator (Sentinel, 3 nodes), then:
```bash
helm upgrade deps ./deps-chart -n gitlab --reuse-values \
  --set redis.sentinel.enabled=true \
  --set 'redis.sentinel.hosts[0]=gitlab-redis-node-0.gitlab-redis-headless:26379'
```
Then edit `gitlab-cr.yaml` `global.redis` to use the Sentinel master name + `sentinels:`
list (commented example is in the file) and re-apply.

### Object storage → ODF
For large/HA object storage, provision OpenShift Data Foundation buckets and repoint
`gitlab-rails-storage`'s `connection` at the ODF S3 endpoint; set `minio.enabled=false`.

---

## 6. Backups

The cloud-native chart ships a `toolbox` pod and an optional backup CronJob. With object
storage wired (as here), backups stream to the `gitlab-backups` bucket:
```bash
# Ad-hoc backup via the toolbox
oc exec -it deploy/gitlab-toolbox -n gitlab -- backup-utility
# Restore
oc exec -it deploy/gitlab-toolbox -n gitlab -- backup-utility --restore -t <timestamp>
```
Enable the scheduled backup CronJob in the CR under `gitlab.toolbox.backups.cron`.

---

## 7. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| CR stuck `Not reconciled` | Chart version unsupported by Operator | Set a `chart.version` the Operator supports |
| Webservice can't reach DB | Wrong `global.psql.host` or secret key | Confirm service DNS + `gitlab-postgresql` secret |
| Redis auth failures | `global.redis.auth` secret/key mismatch | Match deps-chart `gitlab-redis` secret |
| Object storage 403/timeouts | MinIO endpoint/keys wrong in `gitlab-rails-storage` | Check the `connection` secret + MinIO service |
| nginx-ingress pod CrashLoop | Bundled ingress on OCP (no SCC) | Keep it disabled; use Routes |
| CNPG Cluster stuck `Setting up primary` | CNPG operator not installed | Install CloudNativePG from OperatorHub |
| Postgres missing extensions | postInitSQL not applied | CNPG runs `pg_trgm`,`btree_gist` via `postInitSQL`; verify Cluster spec |

---

## 8. Uninstall

```bash
oc delete -f gitlab-cr.yaml -n gitlab
helm uninstall deps -n gitlab
oc delete pvc -l app.kubernetes.io/part-of=gitlab-deps -n gitlab   # datastores are retained by default
# Operator (if removing entirely):
oc delete project gitlab-system
```
