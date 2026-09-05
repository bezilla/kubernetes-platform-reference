# Kubernetes Platform Reference

[![CI](https://github.com/bezilla/kubernetes-platform-reference/actions/workflows/ci.yml/badge.svg)](https://github.com/bezilla/kubernetes-platform-reference/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Kubernetes 1.34](https://img.shields.io/badge/Kubernetes-1.34-326ce5)
![Argo CD 3.5](https://img.shields.io/badge/Argo%20CD-3.5-ef7b4d)
![Gateway API](https://img.shields.io/badge/Gateway%20API-not%20Ingress-7241d6)

The paved-road layer other engineers deploy on: one reconciler, one authored
Helm chart as the interface, and four guardrails that refuse anything that
misses the road. `make up` builds all of it on a local kind cluster and does not
return until every component is green.

It is written for two readers. **If you are an app team**, the only section you
need is [how an app team deploys](#how-an-app-team-deploys) — twenty lines of
YAML and you are on the internet with TLS. **If you are the platform engineer
who maintains this**, everything after that is how it is built and why.

---

## The result

![The Argo CD app-of-apps tree, every Application Synced and Healthy](docs/images/argocd-tree.png)

Nine Applications. One of them — `platform-root` — is the only thing applied by
hand; it produces the other eight. Adding a platform component means adding a
file to `platform/applications/` and committing, never `helm install`.

![The sample workload answering over HTTPS through Gateway API](docs/images/https-demo.png)

![Six violations refused, the compliant deploy admitted](docs/images/guardrails-demo.png)

---

## Quickstart

**Prerequisites**

| | |
|---|---|
| Docker | **8 GiB of memory, minimum.** See below — this is the one that bites. |
| [kind](https://kind.sigs.k8s.io) | creates the cluster |
| kubectl, [helm](https://helm.sh), git | |
| [gitleaks](https://github.com/gitleaks/gitleaks) | only for `make init`; the pre-push gate fails closed without it |

> **Docker memory is not a suggestion.** The platform settles at about 4 GiB but
> peaks well above that while four Helm charts unpack at once. Below 8 GiB the
> symptom is not an out-of-memory error — it is the API server going
> unreachable, which reads exactly like a broken cluster and is not one. This
> was diagnosed the hard way at 3.8 GiB. `make up` refuses to start below 7 GiB
> and tells you where the setting is.
>
> **Close other kind clusters first.** Five kind nodes on eight cores starved
> this control plane into a TLS handshake timeout. `make up` warns if it finds
> others running.

```bash
git clone https://github.com/bezilla/kubernetes-platform-reference
cd kubernetes-platform-reference

make init     # points core.hooksPath at .githooks
make up       # ~10 minutes on a first run; pulls five charts
```

`make up` creates the cluster, installs Argo CD, starts an in-cluster Git
server, builds the sample image, publishes this repository to that server,
applies the app-of-apps root, and then **blocks until every Application is
Synced and Healthy**, exiting non-zero if anything is not. It prints a status
table when it finishes.

```bash
make demo     # the three things that prove it works
make status   # applications, edge, guardrails, workloads
make argo     # the Argo CD UI, with the admin password
make down     # delete the cluster and .work/
```

**Trusting the certificate.** The platform creates its own CA at install time.
`make demo-https` writes it to `.work/platform-ca.crt` and verifies against it
with `curl --cacert`. To use a browser, import that file. It is generated per
cluster and is worthless anywhere else — but do not add it to a system trust
store and forget about it.

---

## How an app team deploys

This is the entire interface. There is no Deployment to write, no Service, no
HTTPRoute, no Certificate, no security context, and no resource arithmetic.

`apps/quote-api/values.yaml`:

```yaml
owner:
  team: payments                  # required — becomes the labels that page you
  contact: payments@example.com   # required
  description: Quote pricing API. Instrumented with OpenTelemetry end to end.

image:
  repository: platform.local/quote-api
  tag: "0.1.0"                    # `latest` is rejected, twice: by the schema
                                  # and again at admission
replicas: 3

port: 8080
resources:
  tier: nano                      # nano | small | medium | large

health:
  path: /healthz

ingress:
  enabled: true
  subdomain: quote-api            # -> https://quote-api.apps.platform.test

env:
  API_ADDR: ":8080"
```

Commit it. Argo CD applies it. **That is the deploy** — there is no pipeline
step and no `kubectl`.

### What you got without asking for it

| | |
|---|---|
| **HTTPS** | A cert-manager certificate on a shared Gateway. You never see an issuer, a CSR or a renewal. |
| **A hostname** | `<subdomain>.apps.platform.test`, with plaintext redirected to HTTPS. |
| **Resource limits** | From `tier`, not from you guessing millicores. The platform can retune every service on the cluster by editing one map. |
| **A restricted security profile** | Non-root, read-only root filesystem, all capabilities dropped, seccomp, no mounted service-account token. |
| **Zero-downtime deploys** | A readiness probe, a startup probe, `maxUnavailable: 0`, and a PodDisruptionBudget when you run more than one replica. |
| **Telemetry** | `OTEL_*` pointing at the platform collector, plus resource attributes naming your team and environment. |
| **Ownership labels** | Derived from `owner`, on every object. This is what answers "who do I page" at 03:00. |

### Why `tier` instead of numbers

Because teams should not have to reason about millicores, and because a
platform that lets thirty teams each invent their own numbers cannot ever retune
anything. `resources.custom` exists for the service that genuinely does not fit,
and using it is meant to be a conversation rather than a default.

### If you get rejected

Admission control will refuse a deploy that misses the road, and it names the
rule:

```
resource Deployment/tenant-quotes/quote-api was blocked due to the following policies

require-resource-limits:
  autogen-containers-must-declare-resources: 'validation failure: Every container
  must set resources.requests.cpu, resources.requests.memory and
  resources.limits.memory. The paved-road chart sets these from `resources.tier`'
```

Everything the chart renders already passes all four guardrails. If you are
seeing one of these, you are writing raw YAML — which is allowed, and is
exactly when the backstop is meant to fire.

---

## How the platform is built

![Architecture: Git to running workload, and the seam between the platform team and the app team](docs/images/platform-architecture.svg)

**One reconciler.** Argo CD, app-of-apps. Only two things are installed
imperatively: Argo CD, because a reconciler cannot reconcile itself into
existence, and a Git server, because Argo CD needs something to reconcile from.
Everything else is an Application in `platform/applications/`. DESIGN.md sets
out why this is not split into Flux-for-platform and Argo-for-apps, what that
split buys, and the write-loop failure mode of two engines over overlapping
manifests.

**Gateway API, not Ingress.** The platform owns `GatewayClass` and `Gateway`;
app teams own `HTTPRoute`. Nothing an app team writes names Envoy, so the
implementation can be replaced without touching a tenant namespace. Under
Ingress the equivalent knobs are vendor-specific annotations, which hard-code
your proxy into thirty repositories and fail silently when misspelled.

**The chart is the interface.** `charts/paved-road` is the seam between the
platform and its tenants, and everything it renders satisfies the guardrails by
construction — so a team on the paved road never meets admission control at all.

**Guardrails are enforced, not audited**, and scoped to namespaces carrying
`platform.internal/paved-road: "true"` so they apply to tenants rather than to
the platform's own upstream charts.

| Layout | |
|---|---|
| `bootstrap/` | the two imperative installs, and the app-of-apps root |
| `platform/applications/` | one Argo Application per component |
| `platform/config/edge/` | namespaces, the CA, the Gateway, the NodePort |
| `platform/config/guardrails/` | the four Kyverno policies |
| `charts/paved-road/` | the authored chart — the interface |
| `apps/quote-api/` | one app team's values file |
| `tests/guardrails/` | fixtures for both suites |
| `versions.env` | every pinned version, in one place |

### Onboarding a tenant

Two things: a namespace labelled `platform.internal/paved-road: "true"`, and a
values file. The label is load-bearing in three places at once — the guardrails
select on it, the Gateway's `allowedRoutes` select on it, and it is what an
operator reads to know who owns a namespace. A namespace without it cannot
publish itself through the edge no matter what it writes.

### Testing

```bash
make check          # everything CI runs, no cluster needed
make lint           # chart lint + render + schema + manifest validation
make policy-test    # every guardrail against fixtures, offline
make demo-guardrails  # the same, through live admission control
```

Both guardrail suites assert that compliant resources **pass** as well as that
violations fail. That is not symmetry for its own sake: a policy that matches
everything and a policy that matches nothing look identical if you only check
one direction, and this repository shipped the first kind for a day. See
DESIGN.md.

---

## Related

- **[terragrunt-reference-architecture](https://github.com/bezilla/terragrunt-reference-architecture)** —
  the cloud-infrastructure half. The AWS accounts, VPCs, EKS clusters and
  observability pipeline that a platform like this one runs on top of.
- **[otel-service-reference](https://github.com/bezilla/otel-service-reference)** —
  the instrumented workload. The service deployed here through the paved-road
  chart, and where its OpenTelemetry wiring comes from.

Together: the cloud underneath, the platform in the middle, the application on
top.

## Documents

- **[DESIGN.md](DESIGN.md)** — decisions, rejected alternatives, and the four
  bugs that changed how this is tested
- [ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md) · [SECURITY.md](SECURITY.md)
