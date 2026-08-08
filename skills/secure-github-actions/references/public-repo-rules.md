# Manual Security Review

The deterministic scan is necessary but not sufficient. Review these controls
for every affected workflow:

- declare least-privilege top-level `permissions:` without breaking reusable
  workflow caller requirements;
- prefer `pull_request` to `pull_request_target`; never execute an untrusted PR
  head in a job with secrets or write credentials;
- scope AI action tools when processing untrusted input;
- avoid mutable runtime dependencies such as `npx ...@latest` or a repository
  clone at an unpinned head;
- do not write attacker-controlled values to `GITHUB_ENV` or `GITHUB_PATH`;
- confirm triggers, conditions, environments, and credential flows match the
  intended trust boundary; and
- justify every exact `trusted_actions` entry instead of widening trust for
  convenience.

The readable-version-comment check is intentionally lexical: a non-empty
same-line comment passes mechanically, but the scanner cannot prove that the
comment names the release represented by the SHA. Compare that pair manually.
Treat the absence of a stricter version grammar as a nonblocking observation
unless the repository adopts an unambiguous grammar; do not invent one during
review.

For public repositories, additionally require:

- no secrets or privileged token in fork-PR build, test, lint, or scanner jobs;
- `persist-credentials: false` on checkout unless the reviewed job genuinely
  needs to push; and
- short-lived OIDC exchange instead of long-lived cloud keys when supported.

Do not narrow an existing permission merely because the caller file does not
show the callee's need. A reusable caller caps the callee, and commenting on a
PR with `GITHUB_TOKEN` needs `pull-requests: write` even when the REST API method
is under the issues namespace.
