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
