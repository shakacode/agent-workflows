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
Run metadata is fetched for the receipt's exact positive run attempt, so a
later rerun cannot substitute its result. Approval history remains bound to the
same run; missing historical evidence still fails closed.
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

In-place rollback requires a compatible instruction surface. If a skill or
workflow root from the prior copy installation would remain active but is absent
from the selected release, installation stops before replacing common files
with `STABLE_INSTRUCTION_SURFACE_CONFLICT`. It also stops when the prior exact
revision is unavailable for checking that inventory. The installer does not
recursively delete these roots or discard user changes. Normal rollback with
the same skill/workflow roots remains supported; unchanged obsolete managed
documents and helpers are reconciled safely.

For an incompatible rollback, install the selected release into a separate
clean target with `--target /path/to/new-agent-home`, verify it, and explicitly
configure the host to use that home. Preserve the previous home and do not load
both instruction sets together. An explicit development-symlink to stable-copy
reinstall remains supported when its managed skills fit the selected release.
Omitted managed skill links, including links to uncommitted skills in the
recorded development source, cause the same pre-replacement refusal. Unrelated
user skill links are preserved; the source checkout is not modified.

For deliberate branch-following development:

```bash
bin/install-agent-workflows --host codex --channel development
upgrade-agent-workflows --host codex --channel development
```

## Native Plugins

Claude's relative-source native plugin can use the immutable marketplace ref.
Do not first add a branch-backed marketplace and later ask it to switch revisions.

```text
/plugin marketplace add shakacode/agent-workflows@vX.Y.Z
/plugin install scw@agent-workflows
```

Claude's GitHub shorthand appends `@vX.Y.Z`. Confirm the host can pin the initial
fetch before installation. If it cannot, use the copy-mode installer or stop
with `UNKNOWN` rather than executing a mutable branch first.

For stable Codex skills, use the verified
[copy bootstrap](#install-update-and-roll-back). The current native Codex URL
route is **development/unverified**: marketplace `--ref` pins only the catalog,
not the separately fetched plugin code. The `scw` URL entry has no plugin ref or
SHA and therefore fetches the default branch. A stable companion receipt covers
only copied assets and does not make the native Codex plugin stable. Disable the
native plugin before installing stable flat skills.

Use `agent-workflows-status`, `agent-workflows-doctor`, and
`agent-workflows-trust-audit --install-metadata <target>/.agent-workflows-install.json`
to report the installed channel, release ref, and exact commit. In companion
mode these describe the copied assets, not approval of the native plugin code.
