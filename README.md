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

Nine Applications. One of them — `platform-root` — is the only thing applied by
hand; it produces the other eight. Adding a platform component means adding a
file to `platform/applications/` and committing, never `helm install`.

![make up: eight components installed one at a time, then nine Applications Synced and Healthy](docs/images/make-up.svg)

One component at a time, each blocking until it is genuinely Synced *and*
Healthy before the next is created. Argo CD's sync waves do not do this on their
own — they order when a child Application **object** is created, not when its
contents finish syncing — and the difference is the whole of
[DESIGN.md § sync waves](DESIGN.md#what-the-sync-waves-actually-do).

![make demo-guardrails: six violations refused at admission, the compliant deploy admitted](docs/images/guardrails.svg)

Six violations refused at admission, each naming the rule that caught it, and
the same Deployment with nothing broken admitted. Both directions, because a
policy that matches everything and a policy that matches nothing look identical
if you only check one.

![make demo-telemetry: 190 spans arriving at a collector the app team never named](docs/images/telemetry.svg)

The payments team's values file names no endpoint, no exporter and no collector.
The spans arrive anyway.

> Every capture above is real output from one `make up` on an 8-core M1 Pro,
> not a mock-up. CI runs the same bring-up and the same demos on a clean runner
> with no sibling checkout, so the claim is checkable without trusting the
> picture.

---

## Quickstart

**Prerequisites**

| | |
|---|---|
| Docker | 4 CPUs and 5120 MiB minimum, 8 CPUs and 8192 MiB recommended. **Not the containerd image store** — see below. |
| [kind](https://kind.sigs.k8s.io) | creates the cluster |
| kubectl, [helm](https://helm.sh), git | |
| [gitleaks](https://github.com/gitleaks/gitleaks) | only for `make init`; the pre-push gate fails closed without it |
| [kubeconform](https://github.com/yannh/kubeconform) | only for `make lint`, which skips manifest validation with a count when it is absent rather than failing |
| [kyverno CLI](https://github.com/kyverno/kyverno) | only for `make policy-test`, which fails closed without it — a policy suite that quietly does not run is how a policy matching everything reaches production |

> **Turn off Docker's containerd image store.** Docker Desktop enables it by
> default and reports its driver as `overlayfs` rather than `overlay2`. Under
> it, a pulled multi-architecture image is stored as an index whose other
> platforms are referenced but never fetched, and `kind load docker-image` —
> which imports with `--all-platforms` — fails on the missing blob with
> `ctr: content digest sha256:...: not found`. It fails minutes in, only for
> images that were pulled rather than built, so it reads as a kind bug and is
> not one. Settings → General → uncheck *Use containerd for pulling and storing
> images*, restart Docker, and confirm `docker system info --format
> '{{.Driver}}'` says `overlay2`. `make up` refuses to start otherwise.
>
> **Give Docker CPU, but do not max its memory.** Cores are what this platform
> runs out of first. Memory is the one people over-allocate: Docker Desktop
> defaults to half of physical RAM, so a 16 GiB machine hands it about 7934 MiB
> — under the recommended figure — while setting the slider to the full 16 GiB
> leaves macOS nothing and gets the kind container evicted mid-run. On 16 GiB,
> 12288 MiB is a good setting; Docker reports back 200–350 MiB less than the
> slider, so verify with `docker system info` rather than trusting the dialog.
> `make up` checks both CPU and memory, in MiB, before it starts.
>
> **Close other kind clusters first.** Five kind nodes on eight cores starved
> this control plane into a TLS handshake timeout. `make up` warns if it finds
> others running.

```bash
git clone https://github.com/bezilla/kubernetes-platform-reference
cd kubernetes-platform-reference

make init     # points core.hooksPath at .githooks
make up       # ~5 minutes on 8 cores; ~17 on a constrained machine
```

`make up` creates the cluster, installs Argo CD, starts an in-cluster Git
server, builds the sample image, publishes this repository to that server,
installs the eight platform components **one at a time**, applies the
app-of-apps root, and then **blocks until every Application is Synced and
Healthy**, exiting non-zero if anything is not. It prints a status table when it
finishes.

Installing one component at a time is deliberate and is not what Argo CD's sync
waves do on their own — see [DESIGN.md](DESIGN.md#what-the-sync-waves-actually-do).

**Argo CD does not read GitHub.** It reads an in-cluster Git server that
`make publish` mirrors this working tree into. The Applications pin
`targetRevision: main`, so the mirror publishes your checked-out branch under
**`refs/heads/main` on that in-cluster mirror only** — nothing is pushed to
GitHub, and your branch is not renamed. It is what lets the platform be brought
up from a topic branch rather than only from `main`.

```bash
make demo     # the four things that prove it works
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
                    # (manifest validation SKIPS with a count if kubeconform
                    #  is absent; in CI its absence is a hard failure)
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
  the instrumented workload, and where its OpenTelemetry wiring comes from.
  **You do not need it to run this repository.** If a checkout is present at
  `../otel-service-reference`, `make up` builds the real service from it. If it
  is not, the bring-up builds a placeholder from `bootstrap/fallback-workload`
  that serves the same `/healthz` the chart probes, on the same ports, as the
  same non-root user — so the paved road, the edge, the certificate and the
  guardrails are all still demonstrated. What is lost is the telemetry, and
  only that.

Together: the cloud underneath, the platform in the middle, the application on
top.

## Documents

- **[DESIGN.md](DESIGN.md)** — decisions, rejected alternatives, and the four
  bugs that changed how this is tested
- [ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md) · [SECURITY.md](SECURITY.md)
