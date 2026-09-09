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
   the protected release workflow and prevents tag updates and deletion. Tags are annotated
   and immutable; cryptographic tag signatures are not required or checked.
2. A protected GitHub Actions environment named `stable-release` with required
   human maintainers, self-review prevention, and no administrator bypass. The
   approving reviewer must not be the change author or the release initiator.

The workflow cannot safely substitute for those repository settings. If either
protection is absent or uncertain, release status is `UNKNOWN` and promotion
must stop.

## Promotion Contract

Finalize and merge the release version metadata first: `VERSION` and
`.codex-plugin/plugin.json` must agree on `X.Y.Z`. Claude's manifest omits
`version` so its host uses the pinned commit identity. Any declared Claude
version must agree too. No version edits may follow candidate verification.

Dispatch the `Release` workflow from a branch at that **exact final candidate
commit**, with `release=vX.Y.Z`, the full `candidate_sha`, and the merged release
PR's `change_author`. The workflow requires its definition, run head, and checked
out tree to match that SHA. It then runs the complete `CI=true bin/validate`
with read-only permissions and no release environment or write credentials.
Installer, upgrade, rollback, stack, and all other validation suites must run;
partial coverage or a failing suite blocks promotion. Ordinary selected PR
checks cannot substitute for this run. Main pushes also retain full validation
between releases.

Only after this job succeeds does the separate `stable-release` environment
request human approval. The reviewer inspects the exact candidate SHA and full
validation evidence, and must be neither the change author nor release
initiator. After approval is verified, the workflow creates the annotated tag,
checks its object ID, peeled commit, and version, and publishes the release.
It never updates or deletes an existing tag. A failed publication after tagging
requires maintainer investigation and a fresh version; rerunning cannot replace
an immutable tag. Cryptographic signatures are not required.

Successful promotion publishes `agent-workflows-release-receipt.json`. The
receipt binds full verification before tagging, the exact candidate commit,
stable channel, release ref, annotated-tag object, peeled commit, protected
environment, human reviewer, change author, workflow actor, recording time,
repository, workflow path, and exact workflow run ID, attempt, and URL. Keep the
receipt as a GitHub Release asset; the successful workflow run and release asset
are the durable evidence. Protection settings must be verified separately; this
workflow does not configure them or claim they exist.

## Updating A Fork

For routine fork updates, prefer the latest upstream **verified release tag**
over moving `main`. Verify the upstream receipt and bind the fetched annotated
tag object and peeled commit before preparing the update. Open an update PR
that merges that exact upstream commit into the fork while retaining fork
changes, then run the fork's required checks against the resulting commit.
Record the upstream tag, commit, receipt, and fork check results in the PR.

Upstream verification covers upstream content only; it does not attest the
fork's extra commits or conflict resolutions. Publishing the fork's own stable
release requires its own full verification of the final candidate after version
metadata, independent human approval, immutable tag, and receipt. Following
upstream `main` remains an explicit development choice.

## Install, Update, And Roll Back

Authenticate the bootstrap verifier before executing any selected-release code.
Use the SHA-256 pin below from an independently trusted copy of this guide;
never obtain its expected value from the unverified tag, its files, or its
release metadata. If that trusted pin is unavailable, stop. A verifier change
requires review and a new pin in the trusted guide; a mismatch must not be
bypassed. This authenticates the verifier, which then authenticates the release
receipt and protected workflow before the installer can run.

```bash
release=vX.Y.Z
source="$HOME/src/agent-workflows"
(
  set -euo pipefail
  bootstrap_tmp="$(mktemp -d)"
  trap 'rm -rf -- "$bootstrap_tmp"' EXIT
  expected_verifier_sha256="9c15e93e693b3bdeec100ea05355cbd3548c785cd8337183d83656243710dfda"
  git clone --no-checkout --filter=blob:none https://github.com/shakacode/agent-workflows "$source"
  git -C "$source" fetch origin "refs/tags/$release:refs/tags/$release"
  tag_object="$(git -C "$source" rev-parse --verify "refs/tags/$release")"
  candidate="$(git -C "$source" rev-parse --verify "refs/tags/$release^{commit}")"
  git -C "$source" show "$candidate:bin/agent-workflows-release" > "$bootstrap_tmp/verifier.rb"
  ruby -rdigest -e '
    abort "Untrusted bootstrap verifier; stop" unless
      Digest::SHA256.file(ARGV.fetch(1)).hexdigest == ARGV.fetch(0)
  ' "$expected_verifier_sha256" "$bootstrap_tmp/verifier.rb"
  ruby "$bootstrap_tmp/verifier.rb" verify-published \
    --root "$source" --release "$release" --approved-commit "$candidate" \
    --expected-tag-object "$tag_object" --repository shakacode/agent-workflows
  git -C "$source" checkout --detach "$candidate"
  "$source/bin/install-agent-workflows" --host codex --source "$source" --release "$release"
)
```

Use `--host claude` for Claude Code. Before materializing candidate content, the
bootstrap executes only verifier bytes authenticated by the independent pin.
The verified installer then repeats release verification before copying files. It verifies the annotated tag, downloads the fixed
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
Omitted managed skill, document, or helper links, including links to uncommitted
paths in the recorded development source, cause the same pre-replacement refusal.
Unrelated user links are preserved; the source checkout is not modified.

Stack synchronization refuses to overwrite an installed stable target with its
development checkout. Use the explicit release upgrader for stable updates.

For deliberate branch-following development, run the selected checkout's own
installer (`--source` cannot relabel a different development checkout):

```bash
bin/install-agent-workflows --host codex --channel development
upgrade-agent-workflows --host codex --channel development
```

## Native Plugins

Claude's relative-source native plugin can use the immutable marketplace ref.
First verify that release through the copy bootstrap into a separate staging
home; retain its recorded `release_ref`, `tag_object`, and `source_revision`.
Before enabling the native plugin, confirm its installed Git revision equals
that peeled commit. If the host cannot expose and preserve that identity, use
verified copy mode or report `UNKNOWN`. A tag string by itself is not evidence
of approval. Do not first add a branch-backed marketplace and later ask it to
switch revisions.

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
