# Native Workflow Refresh Design

## Goal

Make the installed `scw` plugin consume the latest reviewed commit from the
configured `agent-workflows` marketplace without releases, consumer-repository
copies, or a custom provider runtime.

## Scope

Add one installed command:

```text
agent-workflows-refresh --host codex|claude|auto
```

The command delegates updates to the selected host:

- Codex: `codex plugin marketplace upgrade agent-workflows`
- Claude: update the `agent-workflows` marketplace, then update
  `scw@agent-workflows`

The existing installer publishes this command with the other pack-management
helpers. The command does not install a missing marketplace or plugin; it fails
with concise setup guidance instead.

## Behavior

1. Resolve `codex` or `claude` from `PATH`.
2. Run the host's native marketplace and plugin update commands without shell
   interpolation.
3. Preserve native diagnostic output on failure and return nonzero.
4. Print `REFRESH_COMPLETE host=<host>` after successful completion.
5. In `auto` mode, use the repository's existing host-home detection rule:
   select the only detected host, default to Codex when neither exists, and
   reject an ambiguous machine with both homes.

Refresh is an explicit session/task preflight. It does not mutate workflows in
the background while an operation is running.

## Non-goals

- Provider snapshots or operation handles
- Release creation or automatic version bumps
- Background services, timers, or process supervision
- Garbage collection or copied interpreters
- Consumer-repository adoption changes
- Automatic installation of untrusted or missing marketplaces

## Validation

Tests use fake Codex and Claude executables in isolated temporary homes to prove:

- exact native command arguments and ordering;
- explicit and automatic host selection;
- missing executable and native update failures remain failures;
- the installer publishes the refresh command in copy and symlink modes.

The final change must pass the focused refresh and installer tests plus
`bin/validate`.
