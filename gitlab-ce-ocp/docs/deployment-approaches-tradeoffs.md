# Deployment Approaches & Tradeoffs — GitLab CE on OpenShift

There are three legitimate ways to run GitLab CE on OpenShift. None is "best" in the
abstract; they trade **operational simplicity** against **availability and horizontal
scale**. This document lays out the options so the choice is deliberate.

You told me the target is *production with HA intent* and *bundled in-cluster backing
services*, but that the chart approach itself was *"not sure yet."* That's the right
instinct — so this doc makes the recommendation for you at the end, and the shipped
chart is built so you don't have to commit irreversibly today.

---

## The three options at a glance

| | **A. Omnibus custom chart** (this repo) | **B. Cloud-native Helm chart** | **C. GitLab Operator** |
|---|---|---|---|
| What it is | One `gitlab/gitlab-ce` container, self-authored chart | GitLab's official multi-pod Helm chart | OLM Operator managing the cloud-native chart via a `GitLab` CR |
| Pods | 1 (Omnibus) | ~15+ microservice pods | ~15+, managed by Operator |
| OpenShift SCC handling | Dedicated SCC in this chart | **Not clean OOTB** — you patch SCCs yourself | Handled by the Operator (`nonroot-v2`) |
| True active/active HA | No (single app pod) | Yes | Yes |
| Bundled datastores | Yes (in-container) | Yes, but **not HA-grade** subcharts | Yes, same caveat |
| External HA datastores | Supported via values | Supported | Supported |
| Operational complexity | **Low** | High | Medium (Operator abstracts it) |
| Upgrade model | Change image tag, pod restarts | `helm upgrade`, many moving parts | Bump CR version |
| GitLab support stance | Community/self-supported | Supported on k8s; **rough on OCP** | **Recommended path for OpenShift** (OLM install itself is "experimental") |
| Resource floor | ~8 vCPU / 16 GB one node | Much higher (per-service requests) | Similar to B |
| Time to first login | Minutes | Hours | Tens of minutes |
| Who owns the internals | You (transparent) | GitLab chart | GitLab Operator |

---

## A. Omnibus single-container chart (what this repo ships)

**How it works.** The `gitlab/gitlab-ce` Omnibus image bundles every service. You feed
it one `gitlab.rb` (this chart assembles it into a ConfigMap and injects it via
`GITLAB_OMNIBUS_CONFIG`). One StatefulSet, three PVCs, a Route, a dedicated SCC.

**Strengths**
- **Simplest thing that works on OpenShift.** One pod, one config file, transparent.
- **Genuinely self-contained** — satisfies "bundled in-cluster" literally.
- **Cheap** — runs comfortably on a single 8-vCPU/16 GB node for ≤1,000 users.
- **Easy to reason about and debug** — `oc exec` in and you have a normal Omnibus box.
- **Graceful upgrade path** — flip the `externalServices` toggles to externalize
  Postgres/Redis/object storage with no reinstall; later move to C reusing them.

**Weaknesses / tradeoffs**
- **Not active/active HA.** Single app pod ⇒ brief outage on restart/upgrade/node
  drain. Node-failure *resilient* (PVC reattach), not *zero-downtime*.
- **Bundled Postgres/Redis are single instances** — no standby until you externalize.
- **Vertical scaling ceiling.** You grow the one pod; beyond ~1,000 users you should
  split tiers (i.e. graduate to B/C).
- **Community-supported.** You own the chart. (Omnibus itself is a first-class,
  fully-supported GitLab artifact — it's the *chart* that's yours.)

**Best when:** internal team/department GitLab, ≤~1,000 users, you value simplicity and
low cost, and a few minutes of planned downtime per upgrade is acceptable.

---

## B. Official cloud-native Helm chart

**How it works.** GitLab's `gitlab/gitlab` chart deploys each service as its own
Deployment/StatefulSet (Webservice, Sidekiq, Gitaly, Registry, Shell, plus bundled
Postgres/Redis/MinIO subcharts). Highly configurable via a large `values.yaml`.

**Strengths**
- **Real horizontal HA and scale** — the design target for large installs.
- **Fully supported by GitLab on Kubernetes.**
- Fine-grained control of each component's replicas/resources.

**Weaknesses / tradeoffs**
- **OpenShift friction is the headline problem.** The chart does *not* deploy cleanly
  against OpenShift's default SCCs — its bundled components (notably the NGINX ingress
  controller) lack valid OCP SecurityContextConstraints, so you end up hand-crafting
  SCCs and fighting arbitrary-UID assumptions. This is precisely why GitLab created the
  Operator and points OpenShift users to it.
- **Heavy.** 15+ pods, much higher resource floor, more to monitor and upgrade.
- **Bundled datastores are not production-grade** — GitLab explicitly says use external
  HA Postgres/Redis/object storage for production. So "bundled" and "HA" don't coexist
  here either.
- **Steeper learning curve**, larger blast radius on misconfiguration.

**Best when:** you're on plain Kubernetes (not OCP), or you need large-scale HA and are
willing to run external datastores and manage the chart directly.

---

## C. GitLab Operator (OLM)

**How it works.** An Operator (current line ~2.11.x, 2026) installed via OLM/OperatorHub
watches a `GitLab` custom resource and reconciles the cloud-native chart for you. It
creates the correct OpenShift SCC bindings (`gitlab-app-nonroot` ⇒ `nonroot-v2`),
manages upgrades, and is GitLab's **recommended install method on OpenShift**.

**Strengths**
- **OpenShift-native** — solves the SCC/arbitrary-UID problem that sinks option B.
- **Declarative lifecycle** — upgrade by editing the CR; the Operator does the dance.
- Full HA and scale, same as B, with less hands-on chart wrangling.

**Weaknesses / tradeoffs**
- **OLM-based install is officially "experimental"** and GitLab notes it doesn't
  support issues specific to OLM-deployed instances — so read the current docs and pin
  versions, use *manual* approval strategy, and test upgrades.
- **Requires `cluster-admin`** to install and runs cluster-scoped.
- **Least transparent** — the Operator owns the internals; debugging means learning the
  CR + generated resources.
- Still expects **external HA datastores** for a real production posture.
- Heavier footprint than option A.

**Best when:** you want supported, OpenShift-native, scalable HA GitLab and are willing
to run it as a managed Operator with external datastores.

---

## Decision guide

```
Do you need zero-downtime upgrades and multi-replica throughput NOW?
├── Yes ─► Are you on OpenShift (vs plain k8s)?
│          ├── OpenShift ─► Option C (Operator)  ── recommended for large HA on OCP
│          └── Plain k8s ─► Option B (cloud-native chart)
└── No  ─► Team/department scale, value simplicity & low cost, tolerate brief
           planned downtime on upgrade?
           └── Yes ─► Option A (this chart)
                      └── Need data durability/HA without app HA?
                          └► Option A + external datastores (values-production-ha.yaml)
```

### Recommendation for your case
Given *HA intent* but *bundled backing services* and *"not sure on the chart"*, do a
**staged rollout** rather than committing to the heavyweight path on day one:

1. **Start with Option A (this chart, defaults).** Fast, self-contained, validates your
   cluster's SCC/storage/Route/DNS/SSH reality with one pod.
2. **Move to Option A + external HA datastores** (`values-production-ha.yaml`): HA
   Postgres operator + Redis Sentinel + ODF/S3. This removes every single point of
   *data* failure — the part that actually hurts — while staying simple. **This is the
   recommended steady state for a team-scale GitLab.**
3. **Escalate to Option C (Operator)** only if/when you need zero-downtime upgrades and
   horizontal scale. Because you'll already be on external datastores, that migration is
   a data re-point, not a rebuild.

The point of the shipped chart is that steps 1→2 are a values change, and 2→3 reuses
your datastores — so you're never trapped by the early decision.

---

## Sources
- [GitLab Helm chart docs](https://docs.gitlab.com/charts/)
- [Cloud-native GitLab chart on OpenShift (SCC gap)](https://gitlab.com/gitlab-org/charts/gitlab/-/blob/master/doc/installation/cloud/openshift.md)
- [GitLab Operator docs](https://docs.gitlab.com/operator/) and [Operator SCCs](https://docs.gitlab.com/operator/security_context_constraints/)
- [Operator installation (OLM "experimental" note)](https://docs.gitlab.com/operator/installation/)
- [Red Hat: Install the GitLab Operator on OpenShift](https://www.redhat.com/en/blog/install-the-gitlab-operator-on-openshift)
- [GitLab installation requirements (sizing)](https://docs.gitlab.com/install/requirements/)
- [GitLab reference architectures](https://docs.gitlab.com/administration/reference_architectures/)
