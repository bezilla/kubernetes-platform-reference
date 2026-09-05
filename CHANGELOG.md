# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0]

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
- **CI** with no cluster required: chart lint plus render plus schema
  validation, the policy suite, and the identity gate over all history at
  fetch-depth 0.
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

[Unreleased]: https://github.com/bezilla/kubernetes-platform-reference/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/bezilla/kubernetes-platform-reference/releases/tag/v0.1.0
