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

The JSON document uses `schema: review-finding-v0` and a top-level
`review_findings` array. Findings include a stable `id`, `rule_id`,
`deterministic`, verification, and parsed YAML location. Parse support permits
YAML Date and Time scalars while keeping arbitrary object deserialization
disabled.

When a scan reports a mutable reference, obtain the reviewed commit ID through
the consumer's dependency-update process. The scanner deliberately performs no
network tag resolution and makes no action-upgrade choice.
