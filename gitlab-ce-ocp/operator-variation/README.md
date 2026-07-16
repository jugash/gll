# GitLab CE on OpenShift — Operator variation (with in-cluster dependencies)

This is **Variation 2** of the `gitlab-ce-ocp` package. Where the top-level chart runs
a single self-contained Omnibus pod, this variation runs GitLab via the **GitLab
Operator** — GitLab's *recommended* install method on OpenShift — with the dependent
datastores (**PostgreSQL, Redis, MinIO object storage**) deployed as **in-cluster**
workloads rather than external managed services.

## Why this variation exists

GitLab **removed the bundled Redis / PostgreSQL / MinIO subcharts in 19.0 (chart 10.0)**.
The Operator now *requires* you to supply those datastores yourself. This variation
supplies them **inside the cluster** — so you get the Operator's OpenShift-native,
active/active, zero-downtime-upgrade model, without depending on cloud-managed RDS/
ElastiCache/S3.

The datastores use **license-clean, maintained images** — Red Hat sclorg PostgreSQL,
Valkey (BSD-3), MinIO (AGPL-3.0) — deliberately *not* Bitnami, whose public catalog was
deleted on 2025-09-29 and whose production images now require a paid subscription.

```
   ┌────────────────────────── namespace: gitlab ──────────────────────────┐
   │                                                                        │
   │   GitLab Operator (OLM)  ──reconciles──►  GitLab CR (CE)               │
   │        │                                     │                         │
   │        ▼                                     ▼                         │
   │   Routes / SCCs                     Webservice · Sidekiq · Gitaly ·    │
   │   (managed by Operator)             Shell · Registry  (multi-replica)  │
   │                                              │                         │
   │            ┌─────────────────────────────────┼───────────────┐        │
   │            ▼                    ▼             ▼                ▼        │
   │   gitlab-postgresql      gitlab-redis   gitlab-minio    gitlab-rails-  │
   │   (StatefulSet)          (Valkey)       (S3 buckets)    storage secret │
   │        ▲ deps-chart ────────────────────────────────────────┘         │
   └────────────────────────────────────────────────────────────────────────┘
```

## Contents

```
operator-variation/
├── README.md                          ← you are here
├── gitlab-cr.yaml                     ← the GitLab custom resource (CE) wiring the deps
├── deps-chart/                        ← in-cluster PostgreSQL + Redis + MinIO + secrets
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/  (postgresql, redis, minio, secrets, NOTES)
└── docs/
    ├── operator-architecture.md       ← how the pieces fit, tradeoffs vs Omnibus variation
    └── installation-guide.md          ← OLM install → deps → CR, HA upgrades, ops
```

## How the two variations compare

| | **Omnibus chart** (`../chart`) | **Operator + in-cluster deps** (this) |
|---|---|---|
| GitLab runtime | 1 Omnibus pod | Operator-managed microservices, multi-replica |
| HA (app tier) | No (brief outage on upgrade) | Yes (active/active, rolling upgrades) |
| Datastores | Bundled in the pod | Separate in-cluster: Postgres StatefulSet, Valkey, MinIO |
| OpenShift SCC | Custom SCC for the Omnibus pod | Operator handles GitLab SCCs; deps use `restricted-v2` |
| Complexity | Low | Medium–High |
| Best for | Fast, cheap, team-scale | HA without external managed datastores |

## Quick start

```bash
# 0. Install the GitLab Operator via OLM (cluster-admin) — see installation-guide.md
#    (CloudNativePG operator only needed if you opt into postgresql.mode=cnpg)
# 1. Deploy in-cluster dependencies
oc new-project gitlab
helm install deps ./deps-chart -n gitlab

# 2. Edit gitlab-cr.yaml (domain, host, chart version) and apply
oc apply -f gitlab-cr.yaml -n gitlab

# 3. Watch reconciliation
oc get gitlab -n gitlab -w
```

Full steps, HA upgrades (CloudNativePG + Redis operator), and troubleshooting are in
[`docs/installation-guide.md`](docs/installation-guide.md). Design rationale and
tradeoffs are in [`docs/operator-architecture.md`](docs/operator-architecture.md).

## Verification status

Template control-flow and static YAML validated structurally. `helm lint`/`helm
template` and `oc apply --dry-run` could not run in the authoring sandbox (no network).
**Before applying: run `helm template ./deps-chart` and `oc apply --dry-run=server -f
gitlab-cr.yaml`, and confirm the `chart.version` is one your installed Operator
supports.**
