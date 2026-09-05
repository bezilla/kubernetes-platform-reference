# Security

## Scope

This is a reference platform built to run on a local kind cluster. It is a
demonstration repository, not a deployed service: it contains no real
credentials, no cloud account identifiers and no infrastructure. Still, if you
find a security-relevant defect — an insecure default, a guardrail that does not
guard what it claims, a chart that renders something unsafe — please report it.

A guardrail that silently fails open is the most valuable bug you can report
here, and this repository has shipped one: `disallow-latest-tag` spent a day in
`Enforce` admitting every `:latest` image because its pattern used an operator
Kyverno does not have. See DESIGN.md.

## Reporting

Open a [private security advisory](https://github.com/bezilla/kubernetes-platform-reference/security/advisories/new)
rather than a public issue, or email **bezilla@protonmail.com**. Include the
affected chart, policy or manifest and the impact. No response time is promised.

## What this repository does to stay clean

- **No secrets in Git.** gitleaks runs in the pre-push gate and fails closed —
  if the scanner is missing the push is refused rather than skipped. The one
  Argo CD repository Secret committed here holds no credential; it registers a
  public OCI registry. A private one would come from External Secrets or Sealed
  Secrets, because a repository that is the cluster's desired state has to be
  safe to read.
- **Everything version-pinned.** Chart versions, the kind node image (by digest
  as well as tag), and the CI toolchain, all in `versions.env`. `make lint`
  fails on a floating `targetRevision`.
- **The workload runs restricted.** The paved-road chart renders
  `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`,
  all capabilities dropped, `seccompProfile: RuntimeDefault`, and no mounted
  service-account token. App teams get that without asking and cannot
  accidentally opt out.
- **Admission control is enforced, not audited**, and is proven to reject each
  thing it claims to reject — `make policy-test` offline, `make demo-guardrails`
  against a live cluster.

## What is deliberately insecure, because it is local

These are fine on a laptop and would be serious defects anywhere else:

- **The in-cluster Git server has no authentication.** Anyone who can reach the
  pod can read the repository. It is a stand-in for a real Git provider; delete
  `bootstrap/git-server.yaml` and point at GitHub, and the problem goes with it.
- **Argo CD serves plaintext** (`server.insecure: true`) and is reached through
  `kubectl port-forward`. There is no TLS between your browser and the API.
- **The certificate authority is self-signed and generated per cluster.** It is
  worthless outside the cluster that made it, which is the point — but do not
  add `.work/platform-ca.crt` to a system trust store and forget about it.
- **The Argo CD admin password is the generated initial secret**, still present
  in the cluster. A real install rotates it and deletes the secret.
