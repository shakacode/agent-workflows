# Fixture Consumer Repo

This fixture exists so `bin/validate` can prove that the shared workflow pack
resolves a consumer repo seam when scanned as an installed shared root.

## Agent Workflow Configuration

- **Base branch**: `main`.
- **Pre-push local validation**: `bin/ci-local`.
- **CI change detector**: `script/ci-changes-detector origin/main`.
- **Hosted-CI trigger**: comment command `+ci-run-hosted`; label `ready-for-hosted-ci`.
- **Benchmark labels**: `benchmark` and `hosted-ci-no-benchmarks`.
- **Follow-up issue prefix**: `Follow-up:`.
- **Changelog**: `CHANGELOG.md`; user-visible entries only.
- **Lint / format**: `bin/lint` and `bin/format --check`.
- **Merge ledger**: `script/pr-merge-ledger <PR> --strict`.
- **Docs checks**: `bin/check-links`.
- **Tests**: `bin/test`.
- **Build / type checks**: `bin/build` and `bin/type-check`.
- **Review gate**: `codex review`.
- **Approval-exempt change categories**: workflow, build-config, dependency, lockfile.
- **Coordination backend**: public claim-comment fallback.
