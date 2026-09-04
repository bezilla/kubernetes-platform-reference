# Guardrails

Four `ClusterPolicy` objects, all in `Enforce` mode, all scoped to namespaces
labelled `platform.internal/paved-road: "true"`.

Two things about that scope are deliberate:

**They apply to tenants, not to the platform.** Argo CD installs cert-manager,
Envoy Gateway, Kyverno and the collector from upstream charts this repo does not
control. A policy that rejected those charts would be a policy that stopped the
platform from installing itself, and the usual reaction — carve out an exception
per namespace — ends with a policy that exempts everything interesting. Scoping
to the tenancy label says the same thing once, in one place, and says it about
the thing that actually matters: workloads app teams deploy.

**They are enforced, not audited.** An `Audit` policy produces a report someone
has to read. Every rule here is one the paved-road chart already satisfies, so
enforcement costs a compliant team nothing and costs a non-compliant deploy an
immediate, legible rejection. `make demo-guardrails` is that rejection.

The rule of thumb for adding a fifth: a guardrail should be something the
authored chart already gets right. Then policy is a backstop for the manifests
teams write by hand, not a second interface they have to learn.
