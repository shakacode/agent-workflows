# Audit Commands

Run the trusted scanner rather than relying on grep for YAML structure:

```bash
SECURE_GITHUB_ACTIONS_SKILL_DIR="${SECURE_GITHUB_ACTIONS_SKILL_DIR:-.agents/skills/secure-github-actions}"
"${SECURE_GITHUB_ACTIONS_SKILL_DIR}/bin/secure-github-actions-scan" --json .
```

The scanner reads the repository's `.agents/agent-workflow.yml`
`trusted_actions` sequence. A missing sequence is a closed empty allowlist; an
invalid or wildcard entry fails closed. Every external action still needs a
full commit SHA and readable version comment.

For a replayable snapshot, bind the report to immutable Git state without
changing the consumer:

```bash
git rev-parse HEAD
git status --short
"${SECURE_GITHUB_ACTIONS_SKILL_DIR}/bin/secure-github-actions-scan" --json .
```

Plain grep may help locate review surfaces, but is diagnostic only and must not
replace the parser-backed gate:

```bash
rg -n '^\s*(run|uses|secrets):' .github/workflows --glob '*.{yml,yaml}'
```

The parser-backed scan covers block, folded, and explicitly typed scalars, so it
does not reproduce the line-oriented gaps of the upstream quick-audit commands.
It rejects non-scalar mapping keys everywhere and aliases at security-sensitive
job and step value boundaries rather than deserializing arbitrary YAML objects.
Job-level local `uses:` must name a regular `.github/workflows/*.yml` or `.yaml`
file; step-level local `uses:` must name a regular action directory with a
regular descriptor. Symlinks, traversal, missing descriptors, and references
beneath `.git`, `.codex`, `.tmp`, or `tmp` fail closed.
