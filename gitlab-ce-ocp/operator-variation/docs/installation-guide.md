# Installation & Operations — Operator variation

Deploy GitLab CE on OpenShift via the GitLab Operator with in-cluster datastores:
**PostgreSQL** (StatefulSet), **Valkey** (Redis), and **MinIO** (object storage).

> **Image/license note.** These replace the previously-common Bitnami images, whose
> public catalog was deleted on 2025-09-29 (versioned tags moved to the unmaintained
> `bitnamilegacy` repo; hardened images are now paid Bitnami Secure Images). The stack
> here is license-clean and actively maintained: Red Hat sclorg PostgreSQL, Valkey
> (BSD-3), MinIO (AGPL-3.0). For production object storage, prefer OpenShift Data
> Foundation over MinIO.

> **Postgres image choice.** The default StatefulSet uses `quay.io/sclorg/postgresql-16-c9s`,
> which is built to run under OpenShift's arbitrary-UID `restricted-v2` SCC. The plain
> `docker.io/postgres` image does **not** (it fails UID resolution), so don't swap it in
> without a UID-tolerant image. For HA, switch to `postgresql.mode=cnpg` (see §5).

---

## 1. Prerequisites

- OpenShift 4.12+, `oc` logged in as **cluster-admin** (required to install the Operator).
- **Helm 3.8+** (for the deps-chart).
- *(Only if you choose `postgresql.mode=cnpg` for HA Postgres:)* the CloudNativePG
  operator installed from OperatorHub. Not needed for the default StatefulSet mode.
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
- Services `gitlab-postgresql:5432` (StatefulSet), `gitlab-redis:6379` (Valkey), `gitlab-minio:9000`
- Secrets `gitlab-postgresql`, `gitlab-redis`, `gitlab-objectstore`, `gitlab-rails-storage`
- A Job that creates GitLab's required Postgres extensions (`pg_trgm`, `btree_gist`)
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

### PostgreSQL → CloudNativePG (HA)
The default is a single StatefulSet. For HA, install the CloudNativePG operator
(OperatorHub), then switch modes:
```bash
helm upgrade deps ./deps-chart -n gitlab --reuse-values \
  --set postgresql.mode=cnpg --set postgresql.cnpg.instances=3
```
This replaces the StatefulSet with a 3-node CNPG `Cluster` (streaming replication +
automatic failover). Its read-write service is `gitlab-postgresql-rw`, so update the CR's
`global.psql.host` to `gitlab-postgresql-rw`. Migrate existing data with
`pg_dump`/`pg_restore` if the StatefulSet already held data.

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
| Postgres pod CrashLoop as arbitrary UID | Swapped in `docker.io/postgres` (no UID tolerance) | Use the sclorg image (default) or another arbitrary-UID-safe image |
| Postgres missing extensions | extensions Job failed | Check `job/gitlab-postgresql-extensions` logs; it creates `pg_trgm`,`btree_gist` |
| CNPG Cluster stuck (cnpg mode) | CNPG operator not installed | Install CloudNativePG from OperatorHub, or use default StatefulSet mode |

---

## 8. Uninstall

```bash
oc delete -f gitlab-cr.yaml -n gitlab
helm uninstall deps -n gitlab
oc delete pvc -l app.kubernetes.io/part-of=gitlab-deps -n gitlab   # datastores are retained by default
# Operator (if removing entirely):
oc delete project gitlab-system
```
