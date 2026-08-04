# Public repository rules

## Mechanical rules

### Keep expressions out of `run`

Do not interpolate `${{ ... }}` directly into a parsed `run` value. GitHub
evaluates the expression before the shell parses the script, so attacker-shaped
event data can become shell syntax. Put the expression in an `env` value and
reference the shell variable with quoting appropriate to the selected shell.

### Pass reusable-workflow secrets by name

Do not use `secrets: inherit` on a job that calls a reusable workflow. Declare
only the named secrets the called workflow requires. Review the called workflow
at the same immutable reference before expanding that set.

### Pin external `uses` references

Pin external actions and reusable workflows to an exact 40-character lowercase
commit SHA. Repository-local `./` references are bound by the checkout and are
accepted. Docker actions are accepted only with a `docker://...@sha256:` digest
containing 64 hexadecimal characters. Tags, branches, shortened SHAs, malformed
multiple-`@` references, and floating Docker tags fail.

The consumer's `trusted_actions` allowlist in `.agents/agent-workflow.yml`
answers which external action identities are approved. It is a portable policy
seam, not an organization-settings assumption, and it never makes mutable
references acceptable.

## Manual review beyond the scanner

- Minimize workflow and job permissions; treat write permissions and identity
  tokens as explicit trust-boundary decisions.
- Review event triggers, fork behavior, environments, and approval gates before
  exposing credentials to code influenced by an untrusted contributor.
- Treat `pull_request_target`, privileged reusable workflows, self-hosted
  runners, checkout credential persistence, generated shell, and downloaded
  executables as high-risk surfaces requiring repository-specific review.
- Inspect scripts invoked by `run`; moving an expression into `env` prevents one
  interpolation class but does not make the invoked script or its inputs safe.
- Keep action upgrades in the repository's dependency-review process. This
  skill neither resolves tags over the network nor changes pins.

Malformed YAML and invalid scalar shapes are blocking because a partial scan
must not be mistaken for a clean audit. Supporting fail-closed rule IDs are
`secure-github-actions/invalid-yaml` and
`secure-github-actions/invalid-structure`.
