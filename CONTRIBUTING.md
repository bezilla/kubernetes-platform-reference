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
| `identity` | identity, trailers and secrets over all history at `fetch-depth: 0`, plus the gate's own self-test |
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
- **An allowlist on trailers.** Only three keys may appear in a commit's trailer
  block, and every other key is refused:

  | trailer | rule |
  |---|---|
  | `Signed-off-by` | must be exactly `Paul Bezilla <bezilla@protonmail.com>` |
  | `Verified` | free text |
  | `Measured` | free text |

  This replaced a scan for a list of vendor and tool names. Any tool that stamps
  provenance onto a commit does it through a trailer, so an unlisted key is
  refused whether or not the gate has heard of the thing that wrote it — which a
  list of names cannot do for a tool that ships next week.

  `make test-hook` proves both directions: that the gate rejects each thing it
  claims to, and that it accepts each thing it claims to.

### The trailer rule has one sharp edge

Whether a `Key: Value` line is a trailer depends on **which paragraph it lands
in**. git parses only the last paragraph, and only when the whole paragraph
parses as trailers. So:

```
Add a thing                          Add a thing

Verified: 3 runs, 0 failures.        Verified: 3 runs, 0 failures.

And a closing paragraph.             ← nothing after it
```

The left-hand message ends in prose, so `Verified:` there is **ordinary text**
and the gate does not look at it. The right-hand message ends with that line, so
it **is** a trailer and the key must be on the allowlist. The same words, the
same spelling, two different outcomes decided by what comes after.

This is deliberate — it is git's own definition, and it is the definition the
tools that stamp provenance use, so it is the surface worth policing. A `^Key:`
regex would be simpler and would reject ordinary prose: across the six
repositories in this family there are 53 distinct `Key: Value` shapes that are
*not* trailers, including `So:`, `why:`, `one:` and `docs:`.

The practical consequence: if a push is refused for a trailer you thought was
prose, look at whether it ended up in the final paragraph. And a new evidence
word — `Tested:`, `Confirmed:` — needs adding to the allowlist before it can
land in that position. That is the accepted cost of a tight list.
