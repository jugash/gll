# Operator Variation — Architecture & Tradeoffs

## Where this sits

In the top-level tradeoffs doc, this is **Option C (GitLab Operator)** combined with
in-cluster datastores — effectively the "Phase 3" end-state, but keeping the databases
inside the cluster instead of using cloud-managed services.

The decision that forces this shape: **GitLab 19.0 / chart 10.0 removed the bundled
Redis, PostgreSQL, and MinIO subcharts.** Previously you could let the chart spin up
throwaway datastores; now the Operator expects real, externally-managed ones. This
variation satisfies that requirement with **in-cluster** workloads, which is a valid and
common choice when you don't want a hard dependency on RDS/ElastiCache/S3.

## Component responsibilities

| Layer | Who runs it | Notes |
|---|---|---|
| GitLab app (Webservice, Sidekiq, Gitaly, Shell, Registry) | **Operator** via the `GitLab` CR | Multi-replica, rolling upgrades, OpenShift Routes + SCCs handled for you |
| PostgreSQL | **deps-chart** | StatefulSet (sclorg image) by default; `mode: cnpg` for HA |
| Redis | **deps-chart** | Valkey single primary (default) or Sentinel HA (via Redis/Valkey operator) |
| Object storage (MinIO) | **deps-chart** | S3 buckets for artifacts/LFS/uploads/packages/registry/backups |
| Connection wiring | **deps-chart secrets** ⇄ **CR** | `gitlab-postgresql`, `gitlab-redis`, `gitlab-objectstore`, `gitlab-rails-storage` |

The contract between the two pieces is just **Secret names + Service DNS**. The
deps-chart creates them; the CR references them. Change one, change both.

## OpenShift specifics

- **SCCs:** The Operator installs the GitLab application SCC bindings itself
  (`gitlab-app-nonroot` → `nonroot-v2`) — this is the whole reason to use the Operator on
  OCP rather than the raw cloud-native chart. The **dependencies** (sclorg PostgreSQL,
  Valkey, MinIO) all run as arbitrary non-root UIDs, so they satisfy the default
  `restricted-v2` SCC with only an `fsGroup` — no custom SCC for the deps. The sclorg
  Postgres image is Red Hat's OpenShift-oriented build (arbitrary-UID safe via nss_wrapper);
  the plain `docker.io/postgres` image is not and would need `anyuid`.
- **Ingress → Routes:** Disable the bundled `nginx-ingress` (it lacks a valid OCP SCC out
  of the box). The Operator exposes GitLab through OpenShift Routes. Bring your own TLS
  cert or use the router's default wildcard.
- **cluster-admin:** Required to install the Operator (cluster-scoped SCCs/CRDs). The
  deps-chart itself needs only namespace-level permissions.
- **OLM caveat:** GitLab documents the OLM-based Operator install as *experimental* and
  doesn't support issues specific to OLM-deployed instances. Use the **manual** approval
  strategy, pin versions, and test upgrades in non-prod first.

## HA posture and how to reach full HA

| Tier | Default (this chart) | Production HA upgrade |
|---|---|---|
| GitLab app | Multi-replica via CR (`minReplicas: 2`) | Already HA; tune replicas/HPA |
| PostgreSQL | StatefulSet (sclorg), 1 instance | `postgresql.mode: cnpg` → CloudNativePG 3-node cluster w/ auto-failover |
| Redis | Valkey single primary | Deploy Valkey/Redis operator (Sentinel); set `redis.sentinel.enabled: true` |
| Object storage | Single MinIO | MinIO distributed mode, or switch to OpenShift Data Foundation (ODF/NooBaa) |
| Gitaly | Single StatefulSet | Gitaly Cluster / Praefect (multi-node) — configure in the CR |

**Honest note:** the deps-chart ships *reliable single-instance* datastores by default —
Postgres as a plain StatefulSet, Redis as a single Valkey primary. Neither is HA on its
own. The chart does *not* hand-roll fragile Patroni/Sentinel YAML; the correct in-cluster
HA answer is purpose-built operators — CloudNativePG for Postgres (`postgresql.mode=cnpg`)
and a Valkey/Redis operator for Redis (`redis.sentinel.enabled`). So the ladder is
**single-instance StatefulSets → operator-run HA datastores**, wired via a values flag and
a secret/host name rather than a rebuild.

**Why not Bitnami?** Bitnami's public catalog was deleted on 2025-09-29; versioned tags
now live in the unmaintained `bitnamilegacy` repo and hardened production images require a
paid Bitnami Secure Images subscription. Running a production database on images that get
no security updates is the wrong trade, so this variation standardizes on CloudNativePG,
Valkey, and MinIO/ODF instead.

## When to pick this over the Omnibus variation

Pick **this** when you need real application HA (zero-downtime upgrades, horizontal
throughput) and you want to keep datastores in-cluster. Pick the **Omnibus chart** when
you want the simplest possible footprint for a team and can tolerate a brief planned
outage on upgrade. Both are in the same repo so you can start with Omnibus and move here
later — your object data (in MinIO/ODF) and Postgres dump migrate across.

## Sources
- [GitLab Operator docs](https://docs.gitlab.com/operator/) · [Operator installation (OLM "experimental")](https://docs.gitlab.com/operator/installation/) · [Operator SCCs](https://docs.gitlab.com/operator/security_context_constraints/)
- [Migrate from bundled Redis/PostgreSQL/MinIO (removed in 19.0 / chart 10.0)](https://docs.gitlab.com/charts/installation/migration/bundled_chart_migration/)
- [External Redis](https://docs.gitlab.com/charts/advanced/external-redis/) · [External DB](https://docs.gitlab.com/charts/advanced/external-db/) · [Chart globals](https://docs.gitlab.com/charts/charts/globals/)
- [Red Hat: Install the GitLab Operator on OpenShift](https://www.redhat.com/en/blog/install-the-gitlab-operator-on-openshift)
