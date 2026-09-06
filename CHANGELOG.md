# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **The identity gate allowlists trailers instead of searching for vendor
  names.** The old gate scanned every commit message and every tree in the push
  range for a bracketed list of tool names; across the full history of all six
  repositories in this family, 207 commits, that scan matched nothing. It is
  replaced by an allowlist on the trailer block — `Signed-off-by` carrying
  exactly `Paul Bezilla <bezilla@protonmail.com>`, `Verified` and `Measured`
  carrying free text, every other key refused — so a tool that does not exist
  yet is refused for being unlisted rather than surviving for being unknown.
  Trailers are read with `git interpret-trailers --parse`, git's own definition,
  because a `^Key:` regex would reject ordinary prose in all six repositories.
- **Annotated tags are checked**, which nothing did before: the tagger must be
  the canonical identity and the annotation body is subject to the same
  allowlist.
- **The self-test proves both directions**, thirteen cases including a permitted
  sign-off accepted, a sign-off naming anyone else refused, `Verified` and
  `Measured` accepted, an unlisted evidence key refused, and a mid-message
  `Key: Value` line correctly not treated as a trailer. It captures the hook's
  status with `|| rc=$?` rather than reading `$?` from a bare command, which is
  silently fatal under the `bash -eo pipefail` CI runs steps with, and is
  exercised under `-e`, under plain bash and through its shebang.

### Removed

- The scanner-calibration probes in the pre-push hook. They existed only to
  certify the scan that was removed. The reasoning behind them is kept in
  DESIGN.md, because it still governs how history is swept before publication.

**History was not rewritten.** No force push, no retag. Every existing commit
and tag is untouched; only the rule applied to new pushes changed. Both gates
were run over all 64 commits from `6046540` first: old accepted 64 / rejected 0,
new accepted 64 / rejected 0, disagreements 0.


Nothing yet.

## 0.1.0 — 2026-09-05

### Added

- **One-command bring-up.** `make up` creates a kind cluster on a digest-pinned
  node image, installs Argo CD, starts an in-cluster Git server, builds the
  sample workload, publishes the repository and hands over to the app-of-apps
  root — then blocks until every Application is Synced and Healthy. The wait is
  fail-closed: an unreachable API server is a failure, never a pass.
- **Argo CD as the one reconciler**, app-of-apps over eight Applications:
  repository registration, cert-manager, Envoy Gateway, Kyverno, the platform's
  own edge configuration, the guardrails, an OpenTelemetry collector, and one
  tenant workload.
- **Gateway API edge.** One shared `Gateway` with a wildcard listener, TLS from
  a cert-manager CA created at install time, plaintext redirected to HTTPS, and
  `allowedRoutes` restricted to namespaces carrying the tenancy label.
- **`charts/paved-road`**, the authored chart that is the platform's interface:
  a values file in, and a running, routable, observable, policy-compliant
  service out. Resource *tiers* rather than millicores, a JSON schema that
  rejects bad values at render time, and a restricted security profile every
  workload gets without asking.
- **Four Kyverno guardrails** in `Enforce`, scoped to tenant namespaces:
  resource limits, no `:latest` or untagged images, ownership labels, and a
  readiness probe with a non-root user.
- **Two guardrail suites.** `make policy-test` runs the real policy files
  against fixture Pods offline; `make demo-guardrails` runs six violations and
  one compliant deploy through live admission control. Both assert that
  compliant resources pass as well as that violations fail.
- **`make demo`** — the app over HTTPS on a cert-manager certificate, the
  guardrail rejections, and a commit that changes the running cluster.
- **CI, including a real bring-up.** Five jobs: chart lint plus render plus
  schema validation, the policy suite in both directions, the identity gate over
  all history at fetch-depth 0, a `cluster` job that installs kind and runs
  `make up` and `make demo` on a runner without the sibling workload repository,
  and a `supply-chain` job running trivy over the tree and both built images
  with an SPDX SBOM kept per image. Every action is pinned by commit SHA.
- **Renovate**, dashboard-only, for the actions, the container bases and every
  pin in `versions.env` — because an immutable pin never picks up a security
  release on its own, and a bot that opens a pull request writes a `refs/pull`
  ref that cannot be removed.
- **`make demo-telemetry`** — spans arriving at a collector the app team never
  named, proving the observability seam rather than asserting it.
- **The pre-push gate**, with a self-test proving it rejects wrong authors,
  wrong committers, attribution in a message, attribution in a tree, and a term
  added and deleted within one push range.
- DESIGN.md, including why this runs one reconciler rather than a Flux/Argo
  split, and the four bugs that changed how the repository is tested.

### Fixed during development

Recorded because each changed the design rather than only the code; DESIGN.md
has the detail.

- `disallow-latest-tag` matched every image and admitted `:latest` for a day —
  Kyverno patterns have no `|` alternation operator.
- The readiness guardrail rejected every well-formed probe: `?*` matches a
  non-empty string, and every probe type is a map.
- The edge deadlocked with the wildcard certificate ordered ahead of the
  ClusterIssuer that signs it. Sync waves are a total order across an
  Application, not per file.
- The offline policy suite reported 42 passing tests while evaluating nothing,
  because namespace selectors do not resolve without a cluster to read labels
  from.
- The Git server served dumb HTTP, which Argo CD's go-git client cannot read at
  all. Replaced with `git-http-backend` under lighttpd.
- The platform could only be installed from `main`. Every Application pins
  `targetRevision: main` and `publish.sh` mirrored only the checked-out branch,
  so from a topic branch the in-cluster server had no `main` and every
  Application sat in `ComparisonError` until its deadline. `publish.sh` now
  aliases the working branch to `refs/heads/main` on that mirror only; nothing
  is pushed to GitHub and no branch is renamed.
- The fallback workload could never become Ready. It was a pinned nginx that was
  pulled and tagged, on the documented claim that it satisfied every guardrail
  including "probeable" — and the chart probes `/healthz`, which stock nginx does
  not serve. Anyone cloning this without the sibling checkout paid 900s to be
  told nothing. It is built from `bootstrap/fallback-workload` now.
- `make demo-gitops` committed to whatever branch was checked out, leaving demo
  noise in the middle of the reader's own work. It builds its commit with
  plumbing and publishes from a scratch ref now; HEAD, the index and the working
  tree are untouched.
- A `GatewayClass` and the `EnvoyProxy` its `parametersRef` names shared a sync
  wave. When the class landed first, Envoy Gateway latched it at
  `Accepted=False` and never re-evaluated, so no Gateway was created and the
  certificate, Gateway and route behind it could not progress. It is a race, so
  it passed three bring-ups before failing one.
- BSD tar on macOS published AppleDouble `._` entries into the bare mirror,
  where git read them as pack files and errored on every ref. Fixed with
  `COPYFILE_DISABLE=1`.
- Docker Desktop's containerd image store broke `kind load docker-image` on a
  pulled multi-architecture image, minutes into a run and only for pulled
  images, so it read as a kind bug. `make up` refuses it by name now.
- `make lint` reported 29 manifest validation failures on a clean machine when
  the truth was that `kubeconform` was not installed. It skips with a count now,
  never as a pass; in CI its absence stays a hard failure.
- The pre-push gate read each commit's tree with `git grep`, which does not use
  the system regex engine and matches nothing — silently, exiting 0 — for a
  pattern it cannot honour. It reads blobs and pipes them to grep now, and
  probes its own scanner in both directions before trusting it.

[Unreleased]: https://github.com/bezilla/kubernetes-platform-reference/compare/2497d27d43c7f9796836b99c32f6898af9c02854...HEAD

<!-- The compare link points at the first commit, not at a tag, because there is
     no tag. There was a [0.1.0] link here to a release that had never been cut;
     it returned 404 from the day it was written. A version gets tagged when the
     bring-up job has proved itself in CI, and the link gets pointed at it then.
     A reference to a release that does not exist is worse than no reference. -->
