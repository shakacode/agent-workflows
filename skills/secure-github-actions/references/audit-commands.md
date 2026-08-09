# Audit Commands

Run the trusted scanner rather than relying on grep for YAML structure:

```bash
: "${SECURE_GITHUB_ACTIONS_SKILL_DIR:?Set this to an already-resolved absolute trusted-pack skill directory}"
case "${SECURE_GITHUB_ACTIONS_SKILL_DIR}" in
  /*) ;;
  *) echo "SECURE_GITHUB_ACTIONS_SKILL_DIR must be absolute" >&2; exit 1 ;;
esac
test -x "${SECURE_GITHUB_ACTIONS_SKILL_DIR}/bin/secure-github-actions-scan" || {
  echo "trusted-pack secure-github-actions scanner is unavailable" >&2
  exit 1
}
"${SECURE_GITHUB_ACTIONS_SKILL_DIR}/bin/secure-github-actions-scan" --json .
```

Resolve that directory from trusted installed or source-pack bytes before
entering the consumer checkout. Never fall back to `.agents/skills` or execute
a scanner supplied by the consumer under review.

The scanner reads the repository's `.agents/agent-workflow.yml`
`trusted_actions` sequence. A missing sequence is a closed empty allowlist; an
invalid or wildcard entry fails closed. The allowlist applies to
repository-based GitHub Actions and reusable workflows, which still need a full
commit SHA and readable version comment.
For `docker://` references, the scanner enforces digest immutability, but
`trusted_actions` does not mechanically approve the container. Maintainers must
manually review the exact registry, image, and digest.

For a replayable snapshot, bind the report to immutable Git state without
changing the consumer:

```bash
: "${SECURE_GITHUB_ACTIONS_SKILL_DIR:?Set this to an already-resolved absolute trusted-pack skill directory}"
case "${SECURE_GITHUB_ACTIONS_SKILL_DIR}" in
  /*) ;;
  *) echo "SECURE_GITHUB_ACTIONS_SKILL_DIR must be absolute" >&2; exit 1 ;;
esac
test -x "${SECURE_GITHUB_ACTIONS_SKILL_DIR}/bin/secure-github-actions-scan" || {
  echo "trusted-pack secure-github-actions scanner is unavailable" >&2
  exit 1
}
head_sha="$(git rev-parse --verify 'HEAD^{commit}')"
if test -n "$(git status --porcelain=v1 --untracked-files=all)"; then
  echo "Refusing replayable snapshot: checkout is dirty" >&2
  exit 1
fi
printf 'exact HEAD: %s\n' "${head_sha}"
"${SECURE_GITHUB_ACTIONS_SKILL_DIR}/bin/secure-github-actions-scan" --json .
```

This snapshot command refuses staged, unstaged, and untracked state before the
scan. Its report is therefore bound to the clean exact `HEAD` printed directly
above it; a dirty checkout needs a separate review target, not snapshot wording
that implies replayability.

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
beneath `.git`, `.codex`, `.tmp`, or `tmp` fail closed. Recursive discovery
scans regular `action.yml` / `action.yaml` descriptors that are tracked or not
Git-ignored. Unreferenced ignored descriptors are not discovered. Excluded roots are not discovered;
explicitly referenced ignored local actions are resolved and scanned, while
explicit references into excluded roots fail closed.
