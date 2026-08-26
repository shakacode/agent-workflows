# Stable Release Channel

Agent Workflows has two deliberately separate delivery channels:

| Channel | Selector | Intended use |
| --- | --- | --- |
| Stable | exact annotated `vX.Y.Z` tag | human-reviewed installations, updates, and rollback |
| Development | explicit `--channel development` | maintainers who intentionally follow a mutable branch |

Neither installer nor upgrader silently crosses between channels. Reinstall
explicitly when changing channels. Stable mode is copy-only because a symlink
would resume following mutable checkout state.

## Repository Protection Required Before The First Release

Repository administrators must configure both protections before promoting a
stable release:

1. A repository ruleset targeting `refs/tags/v*` that restricts tag creation to
   release maintainers and prevents tag updates and deletion. Tags are annotated
   and immutable; cryptographic tag signatures are not required or checked.
2. A protected GitHub Actions environment named `stable-release` with required
   human maintainers, self-review prevention, and no administrator bypass. The
   approving reviewer must not be the change author or the release initiator.

The workflow cannot safely substitute for those repository settings. If either
protection is absent or uncertain, release status is `UNKNOWN` and promotion
must stop.

## Promotion Contract

The maintainer first confirms that `VERSION`, `.claude-plugin/plugin.json`, and
`.codex-plugin/plugin.json` all contain the same `X.Y.Z`. Create and push one
annotated `vX.Y.Z` tag at the exact approved commit. Do not move or recreate it.

Dispatch the `Release` workflow **from that exact tag ref** with the tag, exact
peeled commit, change author, and annotated-tag object ID. The workflow verifies
that its own definition came from the approved commit, so selecting `main` or
another mutable ref fails closed. The protected environment supplies the
independent exact-head human approval. The workflow rejects a malformed,
missing, lightweight, moved, non-annotated, wrong-commit, or version-mismatched
tag. It does not inspect cryptographic signatures.

Successful promotion publishes `agent-workflows-release-receipt.json`. The
receipt binds the stable channel, release ref, annotated-tag object, peeled
commit, protected environment, human reviewer, change author, workflow actor,
receipt recording time, canonical repository, workflow path, and exact workflow
run ID, attempt, and URL. Keep the receipt as a GitHub Release asset; the
workflow run and release asset are the durable release evidence.

## Install, Update, And Roll Back

Bootstrap copy mode from the exact stable ref before executing any installer:

```bash
release=vX.Y.Z
source="$HOME/src/agent-workflows"
git clone --no-checkout --filter=blob:none https://github.com/shakacode/agent-workflows "$source"
git -C "$source" fetch --force origin "refs/tags/$release:refs/tags/$release"
git -C "$source" checkout --detach "$release"
"$source/bin/install-agent-workflows" --host codex --source "$source" --release "$release"
```

Use `--host claude` for Claude Code. Before materializing candidate content, the
stable bootstrap uses its own regular-file verifier rather than executing the
candidate's release helper. It verifies the annotated tag, downloads the fixed
receipt asset, and reads the public GitHub REST metadata for the release,
workflow run, and environment approval history. Verification binds the
server-reported asset SHA-256 and GitHub Actions publisher, canonical repository, exact release
tag and head, release workflow path, successful run ID and attempt, workflow
actor, and independent `stable-release` reviewer. Public metadata needs no API
credential; unavailable, malformed, rate-limited, or mismatched evidence fails
closed. Candidate files are extracted and copied only after this trust binding
succeeds. A local tag or self-asserted receipt without that evidence fails
closed.
Install metadata records `channel`, `release_ref`, `tag_object`, and the full
peeled `source_revision`.

Successful stable install guidance uses the installed agent home as the
`--shared` root. The temporary exact-release materialization is removed after
installation and is never presented as a reusable validation path.

Updates and rollbacks use the same explicit operation:

```bash
upgrade-agent-workflows --host codex --release vX.Y.Z
```

Choose a newer tag to update or an older tag to roll back. The helper never
selects “latest” and never changes between stable and development implicitly.

For deliberate branch-following development:

```bash
bin/install-agent-workflows --host codex --channel development
upgrade-agent-workflows --host codex --channel development
```

## Native Plugins

Native host commands must also name the immutable ref. Do not first add a
branch-backed marketplace and later ask it to switch revisions.

```text
/plugin marketplace add shakacode/agent-workflows@vX.Y.Z
/plugin install scw@agent-workflows
```

```bash
codex plugin marketplace add shakacode/agent-workflows --ref vX.Y.Z
codex plugin add scw@agent-workflows
```

Claude's GitHub shorthand appends `@vX.Y.Z`; Codex uses `--ref vX.Y.Z`.
Confirm the current host can pin the initial fetch before installation. If it
cannot, use the copy-mode installer or stop with `UNKNOWN` rather than executing
a mutable branch first.

Use `agent-workflows-status`, `agent-workflows-doctor`, and
`agent-workflows-trust-audit --install-metadata <target>/.agent-workflows-install.json`
to report the installed channel, release ref, and exact commit.
