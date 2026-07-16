# GitLab CE on OpenShift — Architecture Review

**Status:** Draft for review
**Scope:** Running GitLab Community Edition (CE) on a Red Hat OpenShift Container Platform (OCP) cluster
**Target profile (from requirements):** Production, high-availability intent, backing services initially bundled in-cluster
**GitLab version baseline:** 18.8.x CE (Omnibus image `gitlab/gitlab-ce`)

> **Read this first — the central tension.** Two of the stated goals pull against each
> other. *"Production HA"* wants redundant, independently-failing datastores and
> multiple stateless app replicas. *"Bundled, in-cluster backing services"* wants a
> single self-contained package. GitLab's own guidance is explicit: bundled
> PostgreSQL/Redis inside the app are **not** an HA configuration, and on OpenShift the
> *recommended* install path is the **GitLab Operator**, because the community
> cloud-native Helm chart does not deploy cleanly against OpenShift's default Security
> Context Constraints (SCCs). This chart deliberately starts from the bundled model
> for a fast, self-contained stand-up, and gives you a **documented, no-reinstall path**
> to externalize datastores and (later) move to the Operator for true active/active HA.
> See `deployment-approaches-tradeoffs.md` for the decision.

---

## 1. What GitLab CE actually is (component model)

GitLab is not one process. Even the single-container Omnibus image runs a supervised
bundle of cooperating services:

| Component | Role | State | Scales by |
|---|---|---|---|
| **Puma** | Rails web/API server (the UI + REST/GraphQL) | stateless | replicas |
| **Sidekiq** | Background job processor (emails, CI events, housekeeping) | stateless | replicas |
| **Workhorse** | Reverse proxy in front of Puma; handles large uploads, Git HTTP, LFS | stateless | with Puma |
| **Gitaly** | The Git RPC service — owns the repositories on disk | **stateful** | sharding / Praefect |
| **GitLab Shell** | Git-over-SSH entry point | stateless | replicas |
| **PostgreSQL** | Primary relational store (projects, users, CI metadata) | **stateful** | primary + replicas |
| **Redis** | Cache, session store, Sidekiq queues | **stateful** | Sentinel/Cluster |
| **NGINX** | In-Omnibus web front end / TLS | stateless | — |
| **Registry** (optional) | Container image registry | stateful (object store) | replicas + object storage |
| **Object storage** | Artifacts, LFS, uploads, packages, backups | **stateful** | external S3 |

The stateless tier scales horizontally trivially. The **stateful tier is where HA is
won or lost**: Postgres, Redis, Gitaly, and object storage each need their own
redundancy strategy. Bundling them in one Omnibus container gives you *none* of that
redundancy — which is the crux of the architecture decision.

---

## 2. Deployment topologies considered

### 2.1 Bundled Omnibus (what this chart ships by default)

```
                        ┌────────────────────────────────────────┐
   Git/HTTPS  ───────►  │  OpenShift Router (HAProxy)             │
   (443)                │  edge/reencrypt TLS                     │
                        └───────────────┬────────────────────────┘
                                        │ HTTP :80
                        ┌───────────────▼────────────────────────┐
   Git/SSH ──────────►  │  Service (ssh :22, LB/NodePort)         │
   (22)                 └───────────────┬────────────────────────┘
                                        │
        ┌───────────────────────────────▼───────────────────────────────┐
        │  StatefulSet gitlab-ce (replicas: 1)  — dedicated SCC + SA     │
        │  ┌──────────────────────────────────────────────────────────┐ │
        │  │ Omnibus container (runit supervisor)                     │ │
        │  │  Puma · Sidekiq · Workhorse · Gitaly · NGINX             │ │
        │  │  PostgreSQL · Redis            (all in-pod)              │ │
        │  └──────────────────────────────────────────────────────────┘ │
        │   PVC data (/var/opt/gitlab)  PVC config (/etc/gitlab)         │
        │   PVC logs (/var/log/gitlab)                                   │
        └────────────────────────────────────────────────────────────────┘
                                        │
                        ┌───────────────▼────────────────────────┐
                        │  CronJob: gitlab-backup (oc exec)       │
                        └─────────────────────────────────────────┘
```

**Availability characteristics.** Data survives node failure because it lives on
PVCs; the StatefulSet reschedules the pod onto a healthy node and reattaches storage
(RWO is fine — only one pod). This gives you *node-failure resilience with an RTO of a
few minutes*, but **not** zero-downtime: during pod restart, upgrade, or node drain,
GitLab is unavailable for that window, and there is a single Postgres/Redis with no
standby. This is a legitimate "production" posture for many internal teams; it is not
"HA" in the active/active sense.

### 2.2 Bundled app + external HA datastores (this chart's `values-production-ha.yaml`)

Same single Omnibus pod, but `postgresql['enable']`/`redis['enable']` are turned off
and GitLab points at:

- **PostgreSQL HA** — e.g. CloudNativePG or Crunchy/Patroni operator, primary + 2
  replicas with automatic failover.
- **Redis HA** — Redis Sentinel (3 sentinels, 1 primary + replicas).
- **Object storage** — OpenShift Data Foundation (ODF/NooBaa/RGW) or external S3 for
  artifacts, LFS, uploads, packages, and backups.

**Why this is the sweet spot for "bundled but serious":** the hard-to-recover state
(your database and your Git/artifact data) is now redundant and independently backed
up, so losing the GitLab pod or its node is a non-event for data. The app pod is still
single, so you still take a short outage on upgrade/restart — but no data is at risk.

### 2.3 Full active/active (GitLab Operator or cloud-native chart)

Multiple Puma/Sidekiq/Gitaly/Registry replicas across nodes, external HA datastores,
PodDisruptionBudgets, rolling upgrades with zero downtime. On OpenShift this is the
Operator's job (it also creates the correct `nonroot-v2`-based SCC bindings). This is
out of scope for the shipped chart but is the documented end-state — see the tradeoffs
doc.

---

## 3. OpenShift-specific concerns

OpenShift is stricter than vanilla Kubernetes; these are the things that actually bite.

### 3.1 Security Context Constraints (SCC)
OpenShift's default `restricted-v2` SCC assigns each pod a random high UID and forbids
running as root. The **Omnibus image assumes UID 0** (its `runit` supervisor manages
bundled service users, writes to `/etc/passwd`-style files, and binds internal ports).
Under `restricted-v2` the container crash-loops.

**This chart's approach:** rather than granting the broad, cluster-wide `anyuid` SCC
(the lazy answer you'll see in many blog posts), it creates a **dedicated SCC** with
`runAsUser: RunAsAny` plus a minimal capability set, and binds its *use* to **only this
release's ServiceAccount** via a narrowly-scoped ClusterRole/RoleBinding. Blast radius
is one ServiceAccount in one namespace. Installing it requires `cluster-admin` (SCCs
are cluster-scoped) — that is unavoidable for any GitLab-on-OpenShift install.

> The official cloud-native Helm chart's well-known gap is exactly this: it does not
> ship valid OpenShift SCCs out of the box (e.g. the NGINX ingress controller SCC
> issue), which is *the* reason GitLab steers OpenShift users to the Operator.

### 3.2 Routes vs Ingress
On OCP, prefer the native **Route** over an in-cluster NGINX Ingress controller. The
chart defaults to a Route with `edge` termination (TLS at the router) and configures
Omnibus to listen on plain HTTP and trust `X-Forwarded-Proto: https`, so there's no
double-TLS. `reencrypt` and `passthrough` are supported for stricter in-transit
requirements. An Ingress fallback is provided for non-OCP clusters.

### 3.3 Git over SSH
Git-over-SSH (port 22) **cannot** traverse the HTTP Router. It needs its own
`LoadBalancer` or `NodePort` Service (or a dedicated `passthrough` route on a distinct
port). The chart provisions a separate SSH Service, off the HTTP path.

### 3.4 Storage
- **RWO block storage** (ODF Ceph RBD, cloud block) is correct for the single Omnibus
  pod and for Gitaly — Git repos want low-latency block, not shared NFS.
- Avoid RWX/NFS for `/var/opt/gitlab`; it causes Gitaly performance and locking issues.
- Separate PVCs for **data / config / logs** so you can size, snapshot, and back them
  up independently. `/etc/gitlab` holds `gitlab-secrets.json` — losing it makes backups
  unrestorable, so it is a first-class backup artifact (the CronJob tars it).

### 3.5 Resource sizing (per GitLab reference architecture)
GitLab's baseline for **up to 1,000 users / 20 RPS** is **8 vCPU and 16 GB RAM**.
The chart's defaults request 2 vCPU / 8 GB and cap at 8 vCPU / 16 GB — comfortable for
a team of this size on one node. Larger installs should move stateless tiers to their
own replicas (i.e. graduate to the Operator), not just grow one pod.

### 3.6 Probes and slow boot
First boot runs DB migrations and a full `gitlab-ctl reconfigure` — 5–15 minutes.
Aggressive liveness probes cause restart loops that never let migrations finish. The
chart uses a **startupProbe** (up to ~15 min grace) gating liveness, plus a patient
readiness probe, all hitting `/-/health` and `/-/readiness`.

---

## 4. Failure modes and recovery

| Failure | Bundled (default) | Bundled + external HA datastores |
|---|---|---|
| Node dies | Pod reschedules, reattaches PVC; ~2–5 min outage | Same for app; datastores unaffected |
| Pod OOM/restart | Short outage; data intact on PVC | Short outage; data intact |
| PVC/storage loss | Restore from backup (RPO = last backup) | App PVC loss is trivial; DB/object data safe & replicated |
| Postgres corruption | Restore whole backup | Failover to standby; PITR possible |
| Upgrade | Brief downtime (single pod) | Brief downtime, but zero data risk |
| Region/AZ loss | Not covered | Depends on datastore replication topology |

**RPO** is set by backup frequency (default nightly → up to 24h). Tighten by increasing
CronJob frequency or, in the external model, relying on Postgres PITR + object-storage
versioning. **RTO** for the bundled model is dominated by pod reschedule + boot (a few
minutes) or, for data-loss events, restore time.

---

## 5. Security posture summary

- **Least-privilege SCC** bound to a single ServiceAccount, not cluster-wide `anyuid`.
- **Secrets** for root password, DB/Redis credentials, and object-store keys are
  referenced from Kubernetes Secrets (supply your own or let Omnibus generate the root
  password); nothing sensitive is baked into the image or ConfigMap.
- **TLS** terminated at the Route; HTTP→HTTPS redirect enforced.
- **NetworkPolicy** (optional) restricts ingress to the OpenShift router and SSH.
- **Backups include `gitlab-secrets.json`**, without which a restore cannot decrypt
  2FA/CI secrets — a commonly-missed gap.

---

## 6. Recommendation

For the stated goal, adopt a **two-phase** rollout:

1. **Phase 1 — stand up now (this chart, default values).** Self-contained Omnibus on
   OCP with the dedicated SCC, Route, PVCs, and nightly backups. You get a working,
   node-failure-resilient GitLab in an afternoon and validate cluster specifics (SCC,
   storage class, Route/DNS, SSH exposure).

2. **Phase 2 — externalize state for real durability (`values-production-ha.yaml`).**
   Point GitLab at an HA Postgres operator, Redis Sentinel, and ODF/S3 object storage.
   This removes all single points of *data* failure while keeping the same simple app
   deployment. This is the recommended steady state for a team-scale internal GitLab.

3. **Phase 3 (optional) — active/active.** If you need zero-downtime upgrades and
   multi-replica throughput, migrate to the **GitLab Operator** reusing the same
   external datastores. The Operator is GitLab's supported OpenShift path and handles
   SCCs, scaling, and lifecycle for you.

The tradeoffs behind choosing *where to stop* on that ladder are detailed next.
