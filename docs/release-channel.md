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

Dispatch the `Release` workflow with the tag, exact peeled commit, change
author, and annotated-tag object ID. The protected environment supplies the
independent exact-head human approval. The workflow rejects a malformed,
missing, lightweight, moved, non-annotated, wrong-commit, or version-mismatched
tag. It does not inspect cryptographic signatures.

Successful promotion publishes `agent-workflows-release-receipt.json`. The
receipt binds the stable channel, release ref, annotated-tag object, peeled
commit, protected environment, human reviewer, change author, workflow actor,
receipt recording time, and workflow run URL. Keep the receipt as a GitHub Release asset;
the workflow run and release asset are the durable release evidence.

## Install, Update, And Roll Back

Use an exact release for either host:

```bash
bin/install-agent-workflows --host codex --release vX.Y.Z
bin/install-agent-workflows --host claude --release vX.Y.Z
```

The stable bootstrap verifies the annotated tag, materializes the tagged tree,
and executes that tagged installer. It never installs files from the current
branch. Install metadata records `channel`, `release_ref`, `tag_object`, and the
full peeled `source_revision`.

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
