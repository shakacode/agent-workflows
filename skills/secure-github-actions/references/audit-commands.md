# Audit commands

The scanner reads an explicit consumer root. It does not execute workflow files,
shell fragments, actions, or repository scripts.

Human-readable scan:

```bash
skills/secure-github-actions/bin/secure-github-actions-scan /path/to/consumer
```

Machine-readable scan:

```bash
skills/secure-github-actions/bin/secure-github-actions-scan --json /path/to/consumer > secure-github-actions-findings.json
```

Exit status is `0` only when every discovered workflow and composite action is
clean. Status `1` means one or more policy, malformed-YAML, or invalid-structure
findings. Status `64` means the command or explicit root was invalid.

Discovery is deterministic and path-sorted:

- direct `.github/workflows/*.yml` and `.yaml` files;
- `action.yml` and `action.yaml` files below the consumer root;
- top-level `.codex`, `.git`, `.tmp`, and `tmp` trees are excluded, while a
  nested directory merely named `tmp` remains in scope.

Discovery does not follow symlinks. A workflow or action input that is a
symlink or non-regular file fails closed. A symlinked directory below the
consumer root also blocks recursive composite-action coverage and is reported
without enumerating its target. The explicit consumer root itself is resolved
once to its real directory and bound to that directory's device/inode identity.

For each candidate, the scanner validates every ancestor with `lstat`, requires
a real regular final file, and uses `File::NOFOLLOW` and `File::NONBLOCK` when
the Ruby/platform pair provides them. `NONBLOCK` prevents a concurrent
regular-file-to-FIFO replacement from waiting for a writer before descriptor
validation. It then requires the opened descriptor's `fstat` device/inode to
match a fresh path `lstat`, revalidates the ancestor chain, and only then reads
from the already-open descriptor.

On a Ruby/platform pair without `File::NONBLOCK`, a concurrently substituted
FIFO is still rejected after `open` returns, but the portable layer cannot
guarantee that `open` itself will not wait. Other special-device open semantics
are platform-specific; every non-regular descriptor is rejected once opened.
Ruby's portable file API also does not expose a cross-platform
component-by-component `openat` chain, so an attacker who can concurrently
replace and restore ancestor directories retains a narrow TOCTOU window. Static
symlink, non-regular, changed-inode, root-identity, and observed out-of-root
escapes are never parsed.

The JSON document uses `schema: review-finding-v0` and a top-level
`review_findings` array. Findings include a stable `id`, `rule_id`,
`deterministic`, verification, and parsed YAML location. Parse support permits
YAML Date and Time scalars while keeping arbitrary object deserialization
disabled.

When a scan reports a mutable reference, obtain the reviewed commit ID through
the consumer's dependency-update process. The scanner deliberately performs no
network tag resolution and makes no action-upgrade choice.
