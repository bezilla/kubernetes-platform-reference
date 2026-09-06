# Contributing

This is a solo repository. Changes land by direct push to `main`, with CI
enforced on every push, and pull requests are not merged here. That is a
standing policy rather than a judgment on any particular change.

The mechanical reason, so it does not have to be guessed at: every commit on
`main` has to carry one canonical identity, and every server-side merge mode
rewrites at least one identity field. Squash stamps the platform's `noreply`
address as the committer; Rebase and Merge stamp the merging account's identity.
None of the three produce the required identity, the hook cannot object because
the platform performed the write, and it is not fixable afterwards without
rewriting published history. So the merge button is not an option here, and
"merge your own pull requests" would reintroduce exactly the problem the rule
exists to prevent.

**Issues are open and welcome.** Bug reports, design disagreements and questions
all belong there. A patch described in an issue — a diff, a branch on a fork, or
a clear description — gets read, and if it is right it gets applied and pushed
with credit in the commit message.

## Setting up a clone

```sh
make init       # sets core.hooksPath at .githooks
make test-hook  # proves the pre-push gate rejects what it claims to reject
```

`core.hooksPath` is per-clone configuration: cloning copies the hook *file* and
installs nothing, so `make init` is required in every clone. The same rules run
server-side in the `identity` CI job, which is the copy nobody can forget to
install. The hook also runs `gitleaks` over history and fails closed when it is
not installed, because a secrets gate that skips when its scanner is missing is
not a gate.

Set the identity in the clone as well — the hook checks author *and* committer
on every commit in the push range, and both must match:

```sh
git config user.name  "Paul Bezilla"
git config user.email "bezilla@protonmail.com"
```

## Before you push

```sh
make check     # everything CI runs that needs no cluster
make up        # the whole platform on kind, about five minutes
make demo      # the five proofs
```

`make check` is `lint`, `check-versions`, `check-environments`, `policy-test`
and `identity`. `make up` needs Docker; read the prerequisites in the README
first, particularly the two Docker Desktop defaults that will otherwise cost you
a run.

### What CI runs

| job | what it enforces |
|-----|------------------|
| `chart · manifests` | helm lint, render, values schema, kubeconform, every environment, `versions.env` against every Application, and `make shell-check` |
| `guardrails` | the Kyverno suite, both directions |
| `identity` | identity, attribution and secrets over all history at `fetch-depth: 0`, plus the gate's own self-test |
| `bring-up · demo` | the whole platform built and all five demos run, on a clean runner, on the fallback path |
| `upgrade in place` | the previous chart versions installed, then upgraded to the pinned ones |
| `supply chain` | trivy over the tree and both built images, an SPDX SBOM per image |

## Dependencies are pinned

Every third-party reference is pinned to an immutable identifier: GitHub Actions
by commit SHA, the kind node image by digest, tools by version in
[`versions.env`](versions.env). A tag is a mutable pointer in somebody else's
repository, and "the build changed and nothing in git did" is the class of
problem pinning exists to prevent.

`make check-versions` fails if a chart version in `versions.env` and the same
version in an Application manifest ever disagree. The manifests cannot source a
shell file, so each carries its version literally, and that duplication is
exactly the kind that rots quietly.

Keeping the pins current is [Renovate](renovate.json5)'s job. It is configured
with `dependencyDashboardApproval`, so it writes one dependency-dashboard issue
and nothing else — no branches, no pull requests — until a checkbox is ticked.

That is structural, not a preference. Opening a pull request creates
`refs/pull/N/head`, which GitHub keeps permanently whether the pull request is
merged, closed or deleted; the repository would have to be recreated to remove
it. This repository's own pre-public gate counts `refs/pull` and expects zero.
A bot that opens one makes that count permanently non-zero, and no merge mode
here can produce the required identity anyway.

So an update is hand-work either way: read the dashboard, apply the change
locally, run `make check` and a bring-up, push through the hook.

`versions.env` is a shell file that no packaged manager reads, so each pin in it
carries a `# renovate:` annotation and a custom regex manager reads those. That
covers the two pins nothing else could reach — the kind node image and the
fallback workload's base, which is a build argument rather than a `FROM` line.
The Helm chart versions are annotated too, but moving a control-plane component
is still a deliberate read of its changelog rather than a tick.

## Commit messages

Explain why, not what — the diff already says what. The commits in this
repository's history are the format: what was believed, what turned out to be
true, and what changed as a result.

Two hard rules, both enforced by the pre-push gate over every commit in the push
range and by the `identity` job over all history:

- **One canonical identity**, author and committer, on every commit.
- **No assistant or generated-by attribution** of any kind, in a commit message
  or anywhere in the tree. `make test-hook` proves the gate still rejects each
  thing it claims to reject.
