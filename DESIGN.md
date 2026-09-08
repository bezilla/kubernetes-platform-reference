# Design

Decisions, with the alternatives that were considered and rejected. Where a
decision was made badly the first time, the failure is recorded rather than
quietly corrected — the bugs at the end are the most useful part of this
document, because they are the parts that were not obvious from reading.

---

## Why one reconciler

**Decision.** One Argo CD, app-of-apps, reconciling everything: platform
components and application workloads alike.

The obvious alternative — and a genuinely good pattern — is to split them. Flux
bootstraps the cluster plumbing (CNI, cert-manager, the ingress layer, the
policy engine) and Argo CD handles application delivery on top. Each tool sits
where it is strongest.

**What that split actually buys.** It is not arbitrary. Flux's controllers are
small, composable and CRD-native, which makes them a natural fit for bootstrap:
`HelmRelease` and `Kustomization` are easy to express in a machine-generated
cluster template, and `flux bootstrap` is designed to run before anything else
exists. Argo CD's strengths are the ones app teams care about — a UI that shows
a team its own service, projects with RBAC boundaries, sync windows, per-app
history and rollback. In a large org those are different audiences with
different change cadences: the platform team ships cluster plumbing on a slow,
audited path, and fifty product teams ship services on a fast one. Splitting the
reconcilers lets each path have its own permissions, its own review, and its own
blast radius. It also means a broken application sync cannot wedge the
controller that installs cert-manager.

**Why one Argo CD here anyway.** At this scale the split costs more than it
buys. Two reconcilers is two sets of CRDs, two upgrade cadences, two failure
modes to learn and two places to look when something has not converged — and the
question "why is this resource not what Git says" now has to be asked twice
before it can be answered once. The audience separation that justifies the split
does not exist in a single-cluster reference platform where the platform team
and the app team are the same person. The app-of-apps pattern already provides
the ordering that Flux would have provided at bootstrap, and it does so in the
same object model the app teams are already reading.

**The concrete failure mode of two engines.** The danger is not running both —
it is running both over overlapping manifests. Both reconcilers are level-
triggered and both are authoritative. Give Flux a `HelmRelease` for
cert-manager and Argo an `Application` pointing at the same chart, and each will
observe a live state that does not match its own desired state, correct it, and
immediately observe the other's correction as fresh drift. The result is a write
loop: two controllers overwriting the same objects several times a minute, a
`metadata.generation` climbing without end, audit logs full of changes nobody
made, and API server load that looks like a bug in Kubernetes. It is
particularly nasty because both systems report healthy — each one is
successfully doing exactly what it was told. The failure only shows up as churn.
Preventing it means a hard ownership boundary: a namespace or a path prefix that
one engine owns and the other is forbidden to touch, enforced by RBAC rather
than by convention, plus a rule that no chart is ever installed by both. That
boundary is real work to establish and permanent work to maintain.

**When I would revisit this.** Three triggers, any one of which is enough:

1. **Multi-cluster.** Once the platform manages fleets rather than a cluster,
   Flux's per-cluster bootstrap story and its lack of a central control plane
   become an advantage, not a limitation.
2. **A separate platform team with a separate change process.** When the people
   who upgrade cert-manager are no longer the people who deploy services, and
   the two need different review, different approval and different rollback
   authority, the split stops being architecture and starts being an org chart
   the tooling has to match.
3. **Argo CD becoming the single point of failure it currently is.** Everything
   here goes through one controller. When an Argo CD outage means no team can
   deploy, moving the platform layer to a reconciler with a different failure
   domain buys real availability.

None of those is true of a single-node reference platform, so this repository
runs one reconciler and documents the other pattern rather than half-building
it.

---

## Why Gateway API, not Ingress

**Decision.** Gateway API with Envoy Gateway. No `Ingress` objects anywhere.

Ingress is the older, more widely supported option, and for a single team
serving a single hostname it is perfectly adequate. It was rejected for one
structural reason: **Ingress has no seam between the platform and the app team.**

Everything that distinguishes one ingress controller from another lives in
annotations — timeouts, retries, body size, TLS behaviour, rate limits, header
manipulation. Those annotations are vendor-specific, unvalidated and untyped. An
app team that wants a 30-second timeout writes
`nginx.ingress.kubernetes.io/proxy-read-timeout: "30"` into its own manifest,
and in doing so hard-codes the platform's choice of proxy into the application's
deployment. Multiply that across thirty teams and the ingress controller can
never be replaced: it is not a platform component any more, it is an API that
thirty repositories depend on by name. Worse, an annotation typo is not an
error. It is silence, and the setting simply does not apply.

Gateway API splits the object along the same line the org is split. The platform
team owns `GatewayClass` and `Gateway` — the listeners, the certificates, the
proxy, the decision about which implementation runs. App teams own `HTTPRoute` —
a hostname, paths, a backend and a timeout, all of them typed fields validated
by the API server. Nothing an app team writes names Envoy. Swapping Envoy
Gateway for Istio or Cilium changes the `GatewayClass` controllerName and the
Application that installs it, and changes no `HTTPRoute` in any tenant
namespace. That is the seam Ingress does not have.

The second reason is `allowedRoutes`. A `Gateway` can declare, as a typed field,
which namespaces may attach routes to it. Here that is a label selector on
`platform.internal/paved-road`, so a namespace without the tenancy marker cannot
publish itself to the internet no matter what it writes. Under Ingress the
equivalent control is an admission policy you have to write yourself, because
the object model has nowhere to put it.

**The cost, honestly.** Gateway API is more objects for a simple case, the
ecosystem is younger, and some controllers still lag on the newer conformance
levels. `ReferenceGrant` for cross-namespace backends is a real concept to learn.
For a two-service cluster Ingress would be less to read. This repository is
about the shape of a platform at the point where it has thirty teams, and that
is the point where the annotation problem is unrecoverable.

---

## Why the authored chart is the platform interface

**Decision.** App teams get one chart, `charts/paved-road`, and write only a
values file. They do not write Deployments, Services, HTTPRoutes, Certificates,
security contexts or resource numbers.

The rejected alternatives were:

- **Raw manifests per team.** Every team copies the last team's YAML, including
  its mistakes, and the platform's security posture is whatever the most-copied
  example happened to contain. Improving anything means thirty pull requests
  against thirty repositories.
- **Kustomize bases with per-team overlays.** Better — there is a shared base —
  but overlays are patches, and a patch can reach any field. There is no
  interface, only a starting point and unlimited freedom to diverge, so the base
  cannot be changed safely once teams have patched around it.
- **An operator with a custom CRD.** The right end state at large scale, and the
  wrong place to start: a CRD means a controller to write, run, upgrade and
  debug, and it puts the platform team on the critical path of every deploy. A
  chart is a build-time abstraction with no runtime component to fail.

The chart is a Helm chart because Helm is what Argo CD already renders and what
every team already knows, and because a values file with a JSON schema is a real
contract — `values.schema.json` rejects a bad values file with a readable message
at render time, rather than producing a half-valid pod that admission control
refuses for reasons that point at the chart instead of at the value.

**What the interface deliberately does not expose.** There is no
`securityContext` block to fill in, no `HTTPRoute` to write, no OTLP endpoint to
look up, and no way to request 1.5 CPUs. Resources are a *tier* — `nano`,
`small`, `medium`, `large` — because teams should not be reasoning about
millicores, and because the platform can retune every service on the cluster by
editing one map in `_helpers.tpl`. `resources.custom` exists for the service that
genuinely does not fit, and using it is meant to be a conversation rather than a
default.

Everything the chart renders satisfies all four guardrails by construction. That
is the design goal: a team on the paved road never meets admission control at
all, and policy is a backstop for hand-written manifests rather than a second
interface to learn.

**The escape hatch is real and deliberate.** `podAnnotations`, `podLabels`,
`nodeSelector`, `tolerations`, `volumes` and `envFrom` pass through. An
abstraction with no escape hatch gets abandoned the first time someone needs
something it does not cover; an abstraction where every use of the hatch is
visible is one the platform team can learn from. The rule of thumb: if two
services need the same override, it belongs in the chart.

---

## Why each guardrail exists

Four `ClusterPolicy` objects, all `Enforce`, all scoped by
`namespaceSelector` to namespaces labelled `platform.internal/paved-road: "true"`.

| Policy | Rejects | Why it is worth blocking a deploy over |
|---|---|---|
| `require-resource-limits` | any container without cpu/memory requests and a memory limit | A container with no memory limit can take a node down, and one with no requests cannot be scheduled honestly — it fits anywhere until it does not. On a shared cluster the cost of one unbounded pod is paid by every other pod on its node. |
| `disallow-latest-tag` | `:latest`, and untagged images | A floating tag makes the manifest and the running code two different facts. Two replicas created a week apart run different code, and a rollback returns to whatever `:latest` points at now. It also breaks GitOps outright: if the image reference never changes, Argo sees no drift and has nothing to reconcile, so the cluster can be wrong while every Application reads Synced. |
| `require-ownership-labels` | workloads without `app.kubernetes.io/name`, `platform.internal/team`, `platform.internal/owner` | At 03:00 the only question that matters is who to wake up. Ownership cannot be added later; it has to be on the object when the object is created. |
| `require-probes-and-nonroot` | containers without a readiness probe, or running as root | Readiness is what lets the platform promise zero-downtime deploys — without it Kubernetes marks a pod Ready when its process starts, so the Gateway routes to a container still opening connections. `runAsNonRoot` is the smallest container-security control with a real blast radius: a root process that escapes its container is root on the node. |

**Why scoped to tenant namespaces rather than the whole cluster.** Argo installs
cert-manager, Envoy Gateway, Kyverno and the collector from upstream charts this
repository does not control. A policy that rejected those charts would be a
policy that stopped the platform from installing itself, and the usual reaction
— an exception per namespace — ends with a policy that exempts everything
interesting. Scoping to the tenancy label says the same thing once, about the
thing that actually matters: workloads app teams deploy.

**Why `Enforce` rather than `Audit`.** An `Audit` policy produces a report
someone has to read. Every rule here is one the paved-road chart already
satisfies, so enforcement costs a compliant team nothing and costs a
non-compliant deploy an immediate, legible rejection.

**Why only one rule from the restricted Pod Security Standard.** The full
profile also demands seccomp, capability drops and a read-only root filesystem.
The chart sets all of them; the policy enforces only `runAsNonRoot`. On a real
multi-tenant cluster I would enforce the whole restricted profile via the
built-in Pod Security Admission and keep Kyverno for the rules PSA cannot
express — ownership labels, image tags, resource tiers. Here that would be four
more ways for the demonstration to fail without teaching anything new.

---

## What the sync waves actually do

Waves are used in two places and they behave differently in each. This
distinction cost a deadlock to learn.

**Across child Applications, waves stagger starts. They are not a barrier.**
`platform/applications/` assigns one component per wave, so Argo creates the
Application objects in order. But each child carries its own
`syncPolicy.automated`, so a child begins syncing the moment it exists rather
than waiting for the previous wave to finish. Observed directly:
`otel-collector` at wave 5 reached Synced while `envoy-gateway` at wave 1 was
still Degraded.

That is still worth having. Three concurrent Helm installs plus their CRD
registrations saturated a single-node control plane badly enough that the API
server stopped answering — a TLS handshake timeout that reads like a dead
cluster and is not one.

**Staggering the starts was not enough, and an earlier version of this document
claimed it was.** On an 8-core machine the waves let five charts unpack at once
anyway, because a wave orders when the child Application *object* is created and
nothing more. The node reached roughly 1900% of 800% available CPU, etcd read
latency went from a 100ms budget to 1.0–1.5s, the API server could not answer a
5s lease renewal, and `kube-controller-manager` and `kube-scheduler` both lost
leader election and crash-looped. Nothing reconciled after that, so every
Application sat Progressing forever. The symptom was never memory: that run held
4.6 GiB of 7.7 GiB.

**What actually fixed it was serializing the install outside Argo CD.**
`scripts/up.sh` applies one child Application, blocks in
`scripts/wait-for-app.sh` until it is genuinely Synced *and* Healthy, and only
then creates the next. The manifests are unchanged and still declare their
waves; the bring-up simply refuses to run them concurrently. Once every child
exists and matches, the app-of-apps root is applied and adopts all eight without
reinstalling anything. Steady state is identical — adding a component is still a
file and a commit.

The measured difference, same charts and same deadlines: 8 cores and 11946 MiB
installed all eight components in 171s with zero control-plane restarts, where
the constrained machine took 934s and restarted the controller manager and
scheduler twice each on its successful run.

**Removing `automated` from the children would make waves a real barrier, and
that trade was rejected.** The root would then drive every sync in strict order,
but the children would lose self-healing, and a commit would no longer change
the cluster on its own — which is the property this repository exists to
demonstrate. Serializing in the bring-up script costs nothing at steady state;
removing `automated` would cost the thing being demonstrated.

**Within a single Application, waves hold strictly.** Argo waits for each wave to
become healthy before starting the next. `platform/config/edge` depends on
exactly that for its certificate chain, and deadlocked when the wildcard
certificate was ordered at wave 1 while the ClusterIssuer that signs it sat at
wave 2: Argo waited for a certificate to go Ready before creating the only thing
that could sign it, and would have waited forever. Waves are a total order over
every resource in the Application, not per file.

---

## Drift, and why four Applications were permanently amber

Four Applications sat `OutOfSync` indefinitely while being entirely correct.
Every differing field was written by the API server or by a CRD's own defaulting:
`spec.conversion` on Kyverno's CRDs, `admission` and `emitWarning` on every
`ClusterPolicy`, the `group` and `kind` that Gateway API fills in on any
`parentRef` or `backendRef` that omits them. Nothing set those fields, nothing
can unset them, and a sync cannot remove them.

Argo normalizes this away for the core kinds it ships knowledge of — which is
why cert-manager and Envoy Gateway report Synced with exactly the same
defaulting on their Deployments and Services. It has no such knowledge of a
custom resource, so anything CRD-shaped drifts forever.

**Why this is worth fixing rather than tolerating.** `OutOfSync` is the one
signal that means the cluster no longer matches Git. A dashboard where four of
ten Applications are permanently amber is a dashboard where nobody notices the
fifth. Being able to say "everything is Synced" is the entire value of the
column.

**The rejected alternative** was to write the defaults into the manifests. That
works, and it would mean every `HTTPRoute` an app team ever writes carries four
lines of `group` and `kind` whose only purpose is to keep a dashboard green —
pushing the platform's problem onto the paved road.

**The recorded cost.** Eleven of Kyverno's CRDs were a different problem wearing
the same clothes: the chart renders `labels: {}` and `annotations: {}`, the API
server discards empty maps, and Git ends up holding `{}` where the cluster holds
nothing. Settling that meant ignoring `.metadata.labels` and
`.metadata.annotations` on vendored CRDs — so **a label that chart adds in a
future version will not show as drift**. That is a real if narrow loss of
signal, accepted knowingly, and it is the reason the `ignoreDifferences` blocks
are scoped to a group and kind rather than applied globally.

---

## Why Argo CD reads an in-cluster mirror, not GitHub

**Decision.** Argo CD's repository is a Git server running inside the cluster.
`scripts/publish.sh` mirrors the working tree into it; nothing in the bring-up
reads github.com.

This exists so the demonstration is self-contained: no deploy key to issue, no
network dependency, and a `make demo-gitops` that changes the running cluster
from a commit without pushing anything to a remote anyone else can see.

**The main alias, and what it does not mean.** Every Application pins
`targetRevision: main`, because `scripts/lint.sh` rejects a floating `HEAD` and
the ref Argo tracks therefore has to be a branch name. But `publish.sh` mirrors
whatever branch is checked out. From a topic branch the mirror then had no
`main` at all, and every Application sat in `ComparisonError` — *unable to
resolve 'main' to a commit SHA* — until its deadline expired. The platform could
only be brought up on `main`, which made a branch the one place a change to the
platform could not be tested.

So `publish.sh` publishes the working branch under `refs/heads/main` as well.
**That alias exists only inside the in-cluster mirror.** Nothing is pushed to
GitHub, no branch is renamed, and the repository's own `main` is untouched. On
`main` the two refspecs name the same ref, so the alias is only written when
they differ.

---

## Why the fallback workload is built, not pulled

The workload deployed here is the service from `otel-service-reference`, which
has no published image. A reference platform whose `make up` depends on a second
private repository is a reference platform nobody but its author can run, so
there is a fallback — and the fallback has to be as real as the thing it stands
in for.

The first version was not. It pulled a public `nginx-unprivileged` and tagged
it, on the documented claim that it satisfied every guardrail including
"probeable". Three of the four held: non-root, tagged, resource-bounded. The
fourth did not. The chart points its startup *and* readiness probes at
`/healthz`, and stock nginx serves no such path, so the startup probe failed
fifteen times at two-second intervals, the kubelet killed the container, and the
Application sat `Synced/Degraded` until the 900s per-component deadline. The
container exited 0 each time — nginx shuts down cleanly on SIGTERM — so the pod
described itself as `Completed` while never once being Ready.

The cost fell entirely on the person this repository is written for: anyone
cloning it without the sibling checkout paid 900s to be told nothing useful.

`bootstrap/fallback-workload` is one nginx config on the same pinned base. It
answers `/healthz` on 8080, and answers on 8081 as well because
`apps/quote-api/values.yaml` declares a pricing port and a declared port nothing
listens on is a lie the next reader has to disprove. The base stays pinned in
`versions.env` and is passed in as a build argument, so there is still one place
the version lives.

The general lesson, which is the reason this is written down: **a placeholder
has to satisfy the same contract as the thing it replaces, and the contract here
was the chart's, not the image's.** The probe path is what the chart promises
about any workload on the paved road. It was not fixable by choosing a
better-behaved public image, because no public image serves an arbitrary
application's health path.

---

## What is deliberately not here

| Excluded | Why |
|---|---|
| **Karpenter** | Needs a real cloud account with real instance types and a real scheduler under pressure. On a single-node kind cluster it would have nothing to scale, no capacity to bid for, and no node lifecycle to manage — a Karpenter install here would be a `NodePool` object that never does anything. Documented as a roadmap item on a real cluster rather than faked. |
| **KubeCost / OpenCost** | Cost tooling is only meaningful against real billing data. On kind every number would be zero or invented, which is worse than absent: it teaches a reader to trust a figure that means nothing. |
| **Cluster API** | Solves cluster lifecycle — provisioning, upgrading and scaling clusters as objects. This repository has one cluster, created by one `kind` command. Adding CAPI would be adding the machinery for a problem it does not have. |
| **A service mesh** | mTLS between services, traffic policy, and the observability of a sidecar. Two services do not need it, it roughly doubles the memory of every pod, and the one thing it would demonstrate here — traffic splitting — Gateway API already expresses. |
| **Flux** | See "Why one reconciler". Not excluded because it is worse, but because running two reconcilers over overlapping manifests is a write loop, and running them over disjoint manifests requires an ownership boundary that a single-cluster reference platform has no way to justify. |

The rule applied throughout: speak to these in documentation, never build a stub.
A `NodePool` that never scales anything is not a demonstration of Karpenter, it
is a claim about Karpenter that the repository cannot back.

---

## Scanning history is not grepping a checkout

Before this repository could be made public, its whole history had to be
checked for things that must not ship: credentials, internal hostnames, ticket
keys, personal paths. The obvious tool is `git grep` with a
revision argument, and it is the wrong one.

**`git grep` does not use the system regex engine.** Given a pattern it cannot
honour -- `\b` and `(?i)` among them -- it does not warn, does not error and
does not exit non-zero. It matches nothing and exits 0. From the outside that
is indistinguishable from a clean history, which is the single most dangerous
failure a verification tool can have: it fails in the direction of "everything
is fine".

It was caught by accident. A history sweep reported **zero** email addresses
while the same regex against the checked-out tree reported **ten**. The repo had
not changed between the two commands; only the engine had. Every other count in
that sweep -- ticket keys, personal paths, private IPs, cloud identifiers -- had
come back zero from the same broken invocation, and every one of them would have
been reported as evidence of a clean history.

**A zero from a scanner you have not calibrated is not evidence.** It is the
absence of evidence, and the two look identical in a terminal.

### The corrected shape

Read the blobs out and pipe them to a real grep. To sweep all history:

```sh
git rev-list --objects --all | awk '{print $1}' | sort -u \
  | git cat-file --batch-check='%(objectname) %(objecttype)' \
  | awk '$2 == "blob" { print $1 }' \
  | while read -r oid; do git cat-file blob "$oid"; echo; done \
  | grep -aoIE "$PATTERN" | sort -u
```

To scan one commit's tree, which is what the pre-push gate does per commit:

```sh
while IFS= read -r -d '' entry; do
    meta="${entry%%$'\t'*}"              # <mode> <type> <oid>
    blob_path="${entry#*$'\t'}"          # -z leaves the path unquoted
    read -r _mode blob_type blob_oid <<<"$meta"
    [ "$blob_type" = 'blob' ] || continue
    git cat-file blob "$blob_oid" | grep -qIiE "$PATTERN" \
        && printf '%s\n' "$blob_path"
done < <(git ls-tree -r -z "$COMMIT")
```

Two details that are not decoration. `-z` stops git quoting paths that contain
spaces or unusual bytes, so the scan reports filenames that actually exist. And
the loop variable is `blob_path`, not `path`: in zsh -- the default shell on
macOS, where this is most likely to be pasted -- `path` is tied to `$PATH`, so
assigning to it empties the command search path and every `git` in the loop
fails with "command not found". That was found by running this snippet, not by
reading it.

### Calibrate the scanner, in both directions

Reaching for a different tool is not the durable fix, because you cannot
assume which tool you have. On the machine this was found on, `grep` on PATH
was **ugrep 7.8.4** and `/usr/bin/grep` was **BSD grep**; neither is GNU grep,
and a third machine will differ again.

What survives that is calibration. Before trusting a scan, run the scanner
over a sample that MUST match and a sample that MUST NOT:

```sh
printf 'a known-forbidden sample\n' | grep -qIiE "$PATTERN" \
    || die 'scanner matches nothing -- pattern or engine is broken'
printf 'an ordinary line of prose\n' | grep -qIiE "$PATTERN" \
    && die 'scanner matches everything -- a pass proves nothing'
```

Both directions, for the same reason the guardrail suites check both: a pattern
matching everything and a pattern matching nothing are indistinguishable if you
only ever watch it match. Calibration has to run through the *same code path*
as the real scan -- a check that proves the pattern works under a different
grep than the one doing the scanning proves nothing about the scan.

`.githooks/pre-push` did exactly this: every scan went through one
`matches_forbidden()` function, the hook probed it in both directions on every
invocation, and a probe that came back wrong refused the push rather than
certifying it.

**That scan has since been removed** — see the next section — and the
calibration went with it, because it existed only to certify the scan. The
lesson did not go anywhere. It is why the pre-public sweep of this repository
extracts blobs and pipes them to the system regex instead of asking `git grep`,
why every scan in that sweep is calibrated against a pattern known to be present
before any zero from it is believed, and why a zero from an uncalibrated scanner
is treated as no evidence at all rather than as good news.

---

## Why the identity gate allowlists trailers

The gate used to match every commit message, and every tree in the push range,
against a fixed list of names. By construction it could only ever catch what
somebody had already thought to write down.

The replacement inverts the question. The rule applies to the **trailer block**,
and it is applied by allowlist:

| trailer | rule |
|---|---|
| `Signed-off-by` | must be exactly `Paul Bezilla <bezilla@protonmail.com>` |
| `Verified` | free text |
| `Measured` | free text |
| anything else | refused |

An unlisted key is refused for being unlisted rather than surviving because
nobody added it to a list. A denylist is stale the day an unanticipated key appears; an
allowlist is not. `Verified` and `Measured` are on the list because both are
already in published history, at `bec588e` and `e2e801f`, recording evidence
rather than authorship — and history is not rewritten to suit a new rule.

### Trailers are read with git's parser, not a regex

`git interpret-trailers --parse` defines a trailer as the last paragraph, and
only when the whole paragraph parses as trailers. That is git's own
definition, which is what makes it the right surface.

It also has an edge worth writing down, because it will surprise someone.
**Whether a `Key: Value` line is a trailer depends on which paragraph it lands
in.** `Verified: ...` followed by another paragraph is prose and the gate never
looks at it; the same line as the final paragraph is a trailer and its key must
be allowlisted. In this repository's own history `Verified` appears three
times as prose and once as a trailer, and `Measured` once as prose and twice as a
trailer.

A `^[A-Z][A-Za-z-]*:` regex would be simpler and wrong. This repository's own
history carries **42 `Key: Value` lines that git does not treat as trailers**,
across 35 distinct keys, including `So:`, `why:`, `error:` and `fatal:` —
ordinary English and pasted command output. A regex gate would have rejected
commits here on the day it shipped.

### What did not change

Identity is untouched: author and committer must both be the one canonical
identity, checked per commit. `collect_commits` is byte-identical. Scope is
still `refs/heads` and `refs/tags` and deliberately not `refs/remotes` or
`refs/pull`. gitleaks still runs over history and still fails closed.

Annotated tags are checked now, which nothing did before — the tagger must be
the canonical identity and the annotation body goes through the same allowlist,
because otherwise a tag is a place to put a trailer the commit gate refused.

Both gates were run over all 64 commits reachable from `6046540` before the change landed: the old gate accepted
64 and rejected 0, the new gate accepted 64 and rejected 0, and the count of
commits the old gate accepts and the new one refuses is **0**.

---

## What the upgrade test proves, and how it classifies a failure

`make upgrade-test` runs three phases against one cluster: install the
**previous** pins, upgrade in place to the **pinned** ones, then roll back. It
is a MECHANISM test at the current pins and says so. The static report finds no
compatibility hazard present for it to survive: measured across the four pinned
components, **0** CRD storage-version moves, **0** served-version removals, and
**0** resource-set differences across **164** rendered resources. A green
therefore proves the re-point works in reverse; it cannot prove rollback is safe
in general, because at these pins there is nothing here to be unsafe about.

Rollback is a **re-point**, not `helm rollback`. Every component is owned by an
Application with `selfHeal` and `prune`, so a `helm rollback` on a release Argo
CD manages would be reverted within seconds. Rolling back therefore means
republishing the older revision into the in-cluster mirror as `main` and letting
Argo CD converge backward.

### The phases, and what each gate actually reads

![The upgrade test's three phases: install the previous pins from a scratch commit, then publish the pinned revision behind five gates — the publish landed read from the mirror ref rather than local HEAD, the child specs rewritten, every Application Synced and Healthy held 30s, targetRevision matching the pins, and the workloads carrying the pinned images read from running pods rather than the Deployment spec — then roll back by re-pointing Argo CD](docs/images/upgrade-phases.svg)

Two of those gates are worded the way they are because the obvious version was
wrong, and a diagram of the obvious version would have looked identical.

**The publish gate reads the mirror, not local `HEAD`.** `assert-published-revision.sh`
runs `git rev-parse` *inside the git-server pod* and compares it with the root
Application's `.status.sync.revision`. Asserting against the local checkout
would have passed while the mirror still served the old revision, because the
local repository is the thing that was correct all along.

**The installed-state gate reads running pods, not the Deployment spec.**
Everything above it reads desired state: `targetRevision` is the version Argo CD
was *handed*, and the convergence wait is Argo CD's verdict on its own work. A
spec that moved while no container did would satisfy every earlier gate. So the
last word belongs to `status.containerStatuses[].image` on Running pods, plus
rollout completion — and completion has to include `status.replicas ==
updatedReplicas`, without which the assertion passes on a genuinely stalled
rollout.

### The classification decision

Everything past the mechanism gates is an elimination argument, so what the run
is allowed to conclude depends on what it knows:

![How a rollback failure is classified: a storage verdict of moved skips the live leg and stays green; a failing mechanism gate is red because the defect is ours; a non-converging rollback is red if a source could not resolve, green with a loud compatibility warning if the verdict was none, and UNCLASSIFIED with exit 0 if no verdict was available; a converging rollback that passes the post-rollback gates is green](docs/images/rollback-classification.svg)

The same thing in words, since the diagram is a summary and this is the rule:

- **The rollback converges** — green.
- **A mechanism gate fails** — red. The re-point did not land, the root did not
  rewrite the children backward, or a source could not resolve. That one is
  ours, and `wait-for-platform.sh` returns a distinct exit 4 for an unresolvable
  source precisely so it cannot be misread as compatibility.
- **Every mechanism gate passes and it still will not converge** — green with a
  loud warning. By elimination that is a compatibility problem, which is a fact
  about an upstream release rather than a defect here, and a check that goes red
  every time a maintainer does something ordinary is a check people stop
  reading. The warning names the local causes that present identically —
  OOMKilled, ImagePullBackOff — so nobody concludes "upstream" without looking.
- **The verdict was unavailable and it did not converge** — reported as
  **UNCLASSIFIED**, exit 0. Not green because it worked and not red because this
  repository is at fault: it is a run that did not produce an answer.

Note the asymmetry: an unavailable verdict only changes the outcome when the
rollback *also* fails to converge. An unavailable verdict on a rollback that
converges is an ordinary green.

### The four gates that made the elimination sound

Classification by elimination — *every mechanism gate passed, therefore what
refused is downstream* — is only worth as much as the mechanism gates. All four
were added because the version before them passed on a failure.

**Gates that read desired state cannot see a cluster that did not move.**
Originally every gate read `.spec.source.targetRevision`, the version Argo CD
was *handed*, or Argo CD's own Synced/Healthy verdict on its own work. Nothing
opened a pod. The file already recorded the shape of that failure — a run
reporting "converged in 0s" with four components still on the versions they
started on — and it was caught only because the specs had not moved either. A
run where the specs move and the pods do not would have gone green. The last
gate now reads `status.containerStatuses` off running pods: the spec is what a
pod *asked for*, which mid-rollout is already the new image on a pod that has
not started it.

**The right image on a Running pod is still not a finished rollout.** Against a
live `ImagePullBackOff` on a single-replica Deployment:

```
generation 4  observed 4  desired 1  updated 1  ready 1  available 1
```

Every field agreed and nothing was rolling. The surge pod exists, so
`updatedReplicas` counts it; `readyReplicas` and `availableReplicas` count the
OLD pod still serving. The first version compared exactly those six numbers and
passed, while `kubectl rollout status` timed out against the same Deployment.
The only field that noticed was `status.replicas` at 2 against
`updatedReplicas` 1 — the old ReplicaSet had not gone away. Both conditions are
asserted now.

**Comparing local state against local state proves nothing about the cluster.**
Every version assertion compared one local value with another: `publish.sh`
computes the SHA it pushed and nothing captured it, and the chart-version gates
read a string Argo CD had been handed. Nothing observed whether the in-cluster
Git server actually held the commit, or whether Argo CD ever resolved it. A
publish that silently did nothing — an empty tree, a git-server pod that
restarted and took `/srv/git` with it, a ref pushed under the wrong name — left
all of it passing. There are two reads now because they fail independently:
`git rev-parse` inside the git-server pod catches a publish that never landed,
and `platform-root`'s own `.status.sync.revision` catches Argo CD holding a
stale revision. Argo CD would faithfully report a wrong commit the mirror was
serving, so neither substitutes for the other.

**The same gate has to work in both directions.** The installed-state assertion
takes `ASSERT_VERSION_PREFIX`, so the rollback phase asserts the *previous*
versions with the identical code path rather than a forked copy that could
drift into agreeing with whatever it was given.

### The data plane is not one of Argo CD's Applications

Every green signal above is about Argo CD Applications. The Envoy proxy is not
one: the `envoy-gateway` Application installs the **controller**, and the
controller creates the proxy Deployment, which carries no Argo CD instance label
at all. So the platform can be Synced, Healthy, held through the settle window
and verified on the previous versions while the edge is still coming back up.

That is not hypothetical. Rolling `envoy-gateway` v1.9.1 back to v1.9.0
rebuilds the proxy, nothing waited for it, and the serving assertion failed; the
run before it won the same race. Which side of a rollout an assertion lands on
is not a property of the platform. `wait-for-edge.sh` now polls the proxy
Deployment, selected by the `gateway.envoyproxy.io/owning-gateway-name` and
`-namespace` labels, before anything asserts that the platform serves.

### `curl -sS` exits 0 on a 502

The serving proof asserted less than it appeared to. `demo-https.sh` used
`--cacert`, so it always genuinely asserted the certificate — curl exits 60 when
the chain does not verify. But without `--fail`, `curl -sS` against a 502 exits
**0**: the request succeeded, the server answered, and the answer was an error
page. The proof therefore established that TLS terminated and the certificate
chained to the platform CA, and never that the workload answered at all.

All three requests now carry `--fail`, and the redirect assertion checks for an
explicit `3xx` to an `https://` location rather than accepting whatever came
back.

### The storage-move gate ahead of it

`pin-delta.sh` has already compared the two chart sets without a cluster. If a
CRD's storage version moved between them, rolling back is not slow or risky —
it is impossible, because objects are persisted at the storage version and the
older CRD cannot read what the newer one wrote. The leg is skipped, the run
warns that this pin is a one-way door, and it stays green: an upstream
maintainer's decision about their own API is not a build failure here.

The verdict reaches the leg as an **artifact**, not by running `pin-delta.sh`
inline. That script pulls eight charts from four external registries, and
putting it inside an eleven-minute cluster job would let a registry blip fail
the cluster job for a reason that has nothing to do with the cluster. Locally
there is a fallback at `.work/pin-delta/storage-verdict.txt`, which exists only
if someone ran `make pin-delta` in that working tree — so `make upgrade-test` on
a laptop adds no network dependency of its own, and simply reports
`unavailable` when no verdict is there.

A checked-in verdict file was rejected for the reason such files always fail:
it would go stale silently. Instead the file records a `pins:` line naming
exactly which `previous > pinned` pairs it compared, and the reader rebuilds
that string from `versions.env`. A file describing different pins is not an
answer to the question being asked, so it reads as `unavailable` rather than
being believed. It can go out of date; it cannot do so quietly.

## Answering compatibility without a cluster

Two checks answer statically what the eleven-minute cluster leg answers
dynamically. Both are advisory jobs, both need no cluster, and between them they
cost about a minute.

### `pin-delta.sh` — six checks over two chart sets

It pulls both chart versions, renders each with the values block the Application
actually carries, and compares. Six checks, in order of how badly each one bites:

| Check | What it catches, and why it matters |
|---|---|
| **storage version moved** | Objects are persisted at the CRD's storage version, so the older chart's CRD cannot read what the newer one wrote. Rollback is not slow or risky — it is impossible. This is the one that gates the live leg. |
| **served version removed** | A version something still submits stops being accepted. |
| **resource set changed** | An object the newer chart adds or drops: what a rollback would have to prune or restore. |
| **CRD field removed** | A field the older chart's schema no longer knows about. |
| **CRD field added** | The quiet one. Set a field the newer chart added, roll back, and the API server **silently prunes** it — structural pruning, not rejection, with Argo CD still reporting Synced. Nothing warns you. |
| **constraint tightened** | Validation that moved rather than a field that moved. The only check that breaks **forward**: an object already in the cluster that satisfied the old rule and not the new one fails the sync when the pin lands. |

Three exit codes, and the distinction is the point: `0` ran and found nothing,
`1` ran and found something to read, `2` could not run. A caller that cannot
tell `0` from `2` reports a failed chart pull as a clean bill of health. `1` is
explicitly **not** a build failure — an upstream maintainer tightening a regex
is a fact about their release, not a defect here.

At the current pins it reports 188 findings: 187 added CRD fields, every one of
them Kyverno's, plus one tightened constraint in envoy-gateway
(`securitypolicies.gateway.envoyproxy.io`, where `spec.oidc.provider.issuer`
gained a URL pattern). None of the 188 is actionable here, and that is a
measured claim rather than an assumption: of the 36 distinct flagged field paths
across the nine affected CRDs, **0** are set by anything in this repository —
checked against all 439 distinct paths its manifests, tenant values and
environment files actually set. Eight of those nine CRDs belong to
`policies.kyverno.io`, a group this repository does not use at all.

### `schema-check.sh` — every manifest against every covered Kubernetes version

Validates everything the platform installs against each Kubernetes version in
the CI matrix, which catches an API removed in a version still covered. That is
the one thing the three-leg bring-up matrix catches that a single leg would not,
and it turns out to be answerable in about ten seconds without a cluster.

Two things measurement caught, both of which would have shipped a check that
could not fail:

**`-ignore-missing-schemas` would have made it pass on the exact defect it
exists to find.** A removed API and a custom resource are the same observation
to kubeconform — *no schema for this kind* — so the flag that makes CRDs
tolerable is the flag that makes a removal invisible. Measured on the fixture:
with the flag, `Skipped: 1, Errors: 0`, exit 0; without it, `Errors: 1`, exit 1.
The flag is not used; resources are classified by an explicit list of API groups
that ship with Kubernetes. The list is explicit rather than a `k8s.io` suffix
rule because `gateway.networking.k8s.io` ends in `k8s.io` and is a CRD.

**The obvious classification rule produced 147 false findings.** "A built-in
group with no schema at this version means the API was removed" is wrong:
`kubernetes-json-schema` ships **no `CustomResourceDefinition` schema at any
version**, in either the standalone or the standalone-strict set — 404 on
v1.32.11, v1.33.12 and v1.34.0, both variants. Under that rule every CRD the
four charts install was reported as removed, 49 per leg. A removal is now
detected as a **differential**: present at one covered version and absent at
another. That is a fact about the versions rather than about the schema source,
and it needs no allow-list to maintain.

Its cost is stated rather than hidden: an API removed *before* the oldest
covered version is absent from all three legs, so it lands in "not covered by
the schema source" — a list the run prints, precisely so it cannot be read as a
clean bill of health.

## Bugs, and what they changed

Every one below shipped, passed review by reading, and was found by running
something. They are recorded because each changed how the repository is tested,
not just what it contains. The first four were found while building it; the rest
were found by bringing it up from nothing on a machine that had never run it.

**A guardrail that never fired.** `disallow-latest-tag` was written as
`image: "!*:latest | !*:latest@* "`, which reads as "not `:latest`, and not
`:latest` with a digest" and is neither — Kyverno patterns have no `|`
alternation operator, so the whole string was one literal wildcard that matched
every image. The policy sat in `Enforce` admitting `:latest` without complaint.
Reading the YAML produced the bug and was never going to find it; deploying a
`:latest` image found it in seconds. **This is why `make demo-guardrails` and the
`kyverno test` suite both exist, and why both assert that compliant resources
*pass* as well as that violations fail** — a policy matching everything and a
policy matching nothing look identical if you only check one direction.

**A guardrail that fired on correct manifests.** The readiness rule was
`readinessProbe: {"?*": "?*"}`, meaning "any key with any value" — except `?*`
matches a non-empty *string*, and a probe's only child is `httpGet`, `tcpSocket`,
`exec` or `grpc`, all maps. It rejected every well-formed probe, and the first
thing it blocked was the sample workload. That is the worse direction of the two:
a policy that fires on compliant input teaches teams that the platform is the
obstacle, and the fix they reach for is an exemption rather than a probe.

**A certificate ordered before its issuer.** Described above under sync waves.
The lesson that generalises: waves are a property of the Application, and reading
them per file is how a two-file chain deadlocks.

**A test suite that evaluated nothing.** The first `kyverno test` run reported 42
passing tests with every result marked `Excluded`. The guardrails are scoped by
`namespaceSelector`, offline there is no cluster to read namespace labels from,
and the CLI treated every rule as not-matching and called it a pass.
`tests/guardrails/values.yaml` now supplies those labels. A suite that cannot run
its own rules is the same false confidence as the bug it was written to catch,
wearing a greener colour.

**A platform that could only be installed from `main`.** Described above under
the in-cluster mirror. The shape of it generalises: the Applications and the
publish step each held one half of a contract about which ref Argo would read,
and neither half was wrong on its own. It could only be found by running the
bring-up from a branch, which is the one thing nobody does when the branch is
where the fix lives.

**A fallback workload that could never become Ready.** Described above. The
documentation asserted the property — "probeable" — that the image did not have,
so reading the repository confirmed the claim and only running it disproved it.

**A demonstration that committed to the reader's branch.** `make demo-gitops`
edited `apps/quote-api/values.yaml` in the working tree and ran `git commit` on
whatever was checked out, so every run left a "Run quote-api on N replicas"
commit in the middle of someone's work, and a dirty tree if it failed partway.
It now builds the commit with plumbing and parks it on a scratch ref that is
published and deleted; HEAD, the index and the working tree are never touched.
A demonstration that alters the thing it is demonstrating on is not a
demonstration.

**A `tar` that corrupted the published repository.** BSD tar on macOS writes an
AppleDouble `._name` entry per file to carry extended attributes. Piping the
mirror through it published those into the bare repo, where git read them as
pack files and errored on every ref it resolved. The mirror on disk was clean —
the corruption was introduced in transit. It never failed a bring-up outright,
which is why it survived: it only made every publish log errors that looked like
a damaged repository.

**A history scan that reported zero because it never ran.** Described above.
The shape worth remembering: the tool did not fail, it succeeded emptily, and
an empty success reads as good news. Everything the gate now does about that
follows from one accidental cross-check.

**A telemetry check that reported no telemetry against a working pipeline.**
The first `make demo-telemetry` counted spans by grepping the collector log for
`Span #` and `TracesExporter`. Both are plausible and both are wrong: with
`verbosity: basic` the debug exporter never writes `Span #` -- that is
`detailed` -- and this collector logs the message as `Traces`. It reported zero
spans while 60 were arriving, then explained the zero using a second broken
check that exec'd `/service --help` into a distroless image with no shell and
concluded the instrumented workload was not instrumented. Two confident,
mutually reinforcing wrong answers.

It is the same failure as the history scan above, in a different costume: a
tool that returns nothing, successfully, and a reader who takes nothing for an
answer. The counts now come from summing the exporter's own `"spans": N` field,
and which workload is deployed is decided by what it answers over HTTP rather
than by exec'ing into it.

**A GatewayClass that latched, and a race nobody has explained.** The
`GatewayClass` and the `EnvoyProxy` its `parametersRef` names shared sync-wave 0.
Within a wave Argo CD applies in its own kind order, so which landed first was
not something the manifests decided. When the class went first, Envoy Gateway
refused it -- *Invalid parametersRef: failed to find envoyproxy
platform-edge/platform-proxy* -- and set `Accepted=False`. Without an accepted
class no Gateway is created, so the certificate, the Gateway and the route
behind it could not progress, and `platform-config` sat `OutOfSync` for 626s of
its 900s deadline.

**This one is recorded as unexplained, because it is.** Envoy Gateway watches
`EnvoyProxy` objects, so the referenced object appearing seconds later should
have caused the class to be reconciled again. It did not: the class was still
`Accepted=False` ten minutes on, with the `EnvoyProxy` present that whole time.
Why it latched was never established. Ordering the `EnvoyProxy` into an earlier
wave removes the **trigger** -- the class is no longer admitted before the object
it names -- and says nothing about the **cause**. If the latch has some other
path into it, this fix will not catch that path.

It is also the only bug here that is a race rather than a certainty. It passed
three consecutive bring-ups before failing one, which is an anecdote from a
handful of local runs and not a rate. Whether it has a rate worth quoting is a
thing CI will answer and this document currently cannot.

The reason to write it down this way: every other entry above ends with a
mechanism. This one ends with a mitigation, and a fix whose mechanism is unknown
being filed next to fixes whose mechanisms are known is exactly how a repository
starts overstating what it understands.

**Two host defects that cost two full runs, now refused in preflight.** Docker
Desktop's containerd image store made `kind load docker-image` fail on a pulled
multi-architecture image, minutes into a run, in a way that reads as a kind bug.
And `make lint` reported 29 manifest validation *failures* on a clean machine
when the truth was that `kubeconform` was not installed — a missing checker
reported as a broken repository. `up.sh` now refuses the first by name, and
`lint.sh` reports the second as skipped with a count, because a check that did
not run is not a check that passed.

---

## Related

- [terragrunt-reference-architecture](https://github.com/bezilla/terragrunt-reference-architecture) —
  the cloud-infrastructure half: the AWS accounts, networking, EKS and
  observability that a platform like this one would sit on.
- [otel-service-reference](https://github.com/bezilla/otel-service-reference) —
  the instrumented workload, and where its OpenTelemetry wiring comes from. It
  is optional: absent a checkout at `../otel-service-reference`, `make up`
  builds the placeholder in `bootstrap/fallback-workload` instead, and only the
  telemetry is lost. See "Why the fallback workload is built, not pulled".
