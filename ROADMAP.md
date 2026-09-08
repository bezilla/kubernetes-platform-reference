# Roadmap

What is not here yet, in the order it would be worth adding. Items are here
because they are genuinely useful next, not to pad a list — anything that could
not be demonstrated honestly on a local cluster is in the "requires real
infrastructure" section rather than pretended at.

## v0.2 — Progressive delivery

**Argo Rollouts canary through Gateway API traffic splitting.**

The spine was built first on purpose and this was always the stretch. Everything
it needs is already in place: Gateway API expresses weighted `backendRefs`
natively, Argo Rollouts has a Gateway API traffic-router plugin, and the
paved-road chart already owns the `HTTPRoute` that would carry the weights.

The work is to replace the chart's `Deployment` with a `Rollout` behind a
values flag — `strategy: rolling | canary` — so an app team opts into canary
delivery by changing one line rather than by learning a new object. The
interesting design question is what the platform decides versus what the team
does: step weights and analysis are platform concerns, but the metric that
decides whether a canary is healthy is the team's. The likely answer is that
the platform ships a default `AnalysisTemplate` reading the error rate the
collector already receives, and a team can point at its own.

Deferred because a canary that nobody can see fail is not a demonstration, and
showing it properly needs load generation and a deliberate bad deploy — more
moving parts than the spine had earned at that point.

## v0.3 — ChatOps

**Deployment and policy events into a self-hosted Mattermost.**

The platform currently tells you things by being looked at. Sync failures, a
Kyverno rejection and a rollout going backwards are all events an on-call
person should receive rather than discover.

**On Botkube.** The obvious tool for this, and it publishes a Kubernetes-native
event pipeline that reads policy violations and Argo events well. Its open-source
offering has effectively reached end of life — the project moved to a
commercial model and the free tier lost most of what made it worth wiring up.
Building a reference platform on a component whose community edition is being
wound down would be teaching a dead end. Worth naming here precisely because
it is the tool most people would reach for first.

**Why Mattermost over Slack.** Slack is where most teams actually are, and a
Slack webhook is less work. Mattermost is chosen because it can be run in the
cluster: the whole point of this repository is that `make up` produces something
complete on one machine, and a Slack integration would make the demonstration
depend on an external account, a workspace and a token that cannot be committed.
Self-hosted Mattermost keeps the loop closed and the secret local. The
integration surface is a webhook either way, so pointing it at Slack instead is
a URL change.

## v0.4 — Multi-tenancy with teeth

The tenancy model here is one label and one namespace. The next honest step is
`AppProject` boundaries in Argo CD so a team can only sync its own paths,
`ResourceQuota` and `LimitRange` per tenant namespace, and NetworkPolicy default
-deny with the paved-road chart opening only what a service declares.

This is deferred rather than excluded because it is real platform work that a
single-node cluster can demonstrate — it just was not the spine.

## v0.5 — Environments that are installed, not only rendered

`environments/local.yaml`, `staging.yaml` and `production.yaml` exist and are
checked on every commit: every tenant renders in every environment, the output
validates, it satisfies all four guardrails, and the three demonstrably differ.

What is missing is that only `local` is ever brought up. The honest next step is
not a fourth file, it is the parts of an environment that a values layer cannot
express: the certificate issuer (a self-signed CA locally, ACME above it), the
edge Service type (NodePort on kind, LoadBalancer on a cloud), the DNS zone, and
the Envoy fleet's own sizing. Those live in `platform/config/edge/`, which is
plain YAML rather than a chart, so parameterising them means deciding whether
that directory becomes a chart or gains an overlay — a real design decision, and
the reason this is a roadmap item rather than a patch.

## Decided, and not being built

Recorded here so the question is not reopened from scratch each time.

### Compatibility testing with a second pin set — no

The rollback leg proves the mechanism, not compatibility, because the current
pins contain no compatibility hazard to survive. The obvious next step is a
second, older pin set chosen to contain one. It is not being built.

Every architecture for it has the same defect: to reach a state where rollback
is genuinely hazardous, the *upgrade* has to start from something other than
what the previous phase produced — a seeded cluster, a hand-built CR, a
different starting pin. At that point the rollback is no longer rolling back the
upgrade that was just performed, and it stops being a rollback test. It becomes
a test of whether a particular object survives a particular CRD change, which is
a real question and a different one.

And that question already has a cheaper answer. `pin-delta.sh` compares the two
chart sets statically and reports storage-version moves, removed served
versions, resource-set changes, added and removed CRD fields, and tightened
constraints — in about a minute, with no cluster. The live leg is not the
instrument for it.

**Revisit when a pin bump crosses a minor version.** A patch bump within a minor
is where "no hazard present" keeps being true; a minor is where it stops being a
safe assumption.

### The three-leg bring-up matrix — open, but not for the reason it looked

The matrix runs Kubernetes 1.32, 1.33 and 1.34 and costs roughly 24 minutes.

Two facts changed the shape of this question:

**It is advisory.** The three bring-up legs and `upgrade in place` are not
required status checks — only `chart · manifests`, `guardrails`, `identity` and
`supply chain` gate a merge. Those 24 minutes have never blocked anything. The
cost of keeping the matrix is wall-clock and noise, not merge latency.

**The API-compatibility argument for three legs no longer stands alone.** The
one thing three legs catch that one leg would not is an API removed in a covered
version, and `make schema-check` now answers that statically in about ten
seconds. What the legs still prove by themselves is bring-up *behaviour* under
each version — which is a real thing, and a different claim from API
compatibility.

**The roll-forward question is more urgent than the collapse question.** Support
dates, from [endoflife.date](https://endoflife.date/kubernetes), retrieved
2026-09-08:

| Leg | Released | End of life | Status on 2026-09-08 | Pinned patch | Latest patch |
|---|---|---|---|---|---|
| 1.32 | 2024-12-11 | 2026-02-28 | **EOL, 6 months past** | 1.32.11 | 1.32.13 |
| 1.33 | 2025-04-23 | 2026-06-28 | **EOL, 10 weeks past** | 1.33.12 | 1.33.13 |
| 1.34 | 2025-08-27 | 2026-10-27 | supported, ~7 weeks left | 1.34.0 | 1.34.11 |

So two of the three legs currently test versions that are already out of
support, and the third leaves support inside two months. Deciding whether to
collapse a matrix whose every leg is about to be stale is the wrong order:
**roll the matrix forward first, then decide how many legs it needs.** This
table exists so that decision is made against dates rather than against a
feeling about staleness — and it needs re-reading whenever the pins move.

## Open, and unexplained

### The intermittent `argocd-repositories` fetch stall

Roughly one runner bring-up in three, `argocd-repositories` sits Unknown for
four to six minutes before recovering. Argo CD caches the manifest-generation
failure, so the Application cannot recover while it is polled and a longer
deadline buys nothing but wall clock.

**This is open. It is not explained by the `/var/tmp` spill.** A real defect was
found and fixed while looking for it — lighttpd spilling a request body to a
read-only `/var/tmp`, fixed by `server.upload-dirs = ( "/tmp" )` in
`bootstrap/git-server.yaml` — and that fix is worth keeping on its own merits.
It is not the cause of this stall, and the repository should not claim it is:
the spill threshold was measured at **between 64 KB and 65 KB** and governs
**request bodies only** (a 371,880-byte response with a 130-byte body does not
spill). The CI request bodies that failed were **162 and 303 bytes** — two to
three orders of magnitude below the threshold, so they cannot spill.

What is established: the access log discriminates a client that cut from a
server that stopped early, by comparing logged bytes against the total the
client expected, and the captured failure was SHORT — the server stopped first.
What is not established is why.

The instrumentation is in place and will collect the next occurrence:
de-duplicated condition logging in `wait-for-app.sh`, the git-server stability
check, and `capture-fetch-failure.sh`, which records the repo-server log, the
client-filtered access log, events and object YAML, with a `MANIFEST.txt` that
distinguishes *captured nothing because there was nothing to capture* from
*capture failed*.

## Requires real infrastructure

Not scheduled, because they cannot be shown honestly on kind. See DESIGN.md for
why each is excluded rather than stubbed.

- **Karpenter on a real cluster.** Provisioning, consolidation and spot
  interruption handling against actual instance types, with a workload that
  creates genuine scheduling pressure. The interesting part is what the platform
  chooses on a team's behalf — instance families, consolidation policy,
  disruption budgets — and none of that means anything without a cloud account.
- **Cost visibility.** OpenCost or KubeCost against real billing data, with
  showback per `platform.internal/team`. The ownership labels the guardrails
  already enforce are exactly what this would key on, which is the reason those
  labels are mandatory now rather than later.
- **Fleet management.** Multi-cluster is the point at which the one-reconciler
  decision in DESIGN.md gets revisited.
