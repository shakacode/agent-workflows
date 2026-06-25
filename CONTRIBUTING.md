# Contributing

Thanks for improving the shared agent workflow pack. Keep changes portable,
focused, and easy for consumer repos to adopt.

## Before Opening A PR

- Start from the current `main` branch and keep each PR focused on one workflow,
  helper, or documentation concern.
- Run `bin/validate` before opening or updating a PR.
- Run `rubocop` after Ruby helper or test changes. The repo pins double-quoted
  Ruby strings in `.rubocop.yml`; do not autocorrect the tree unless the PR is
  explicitly a formatting cleanup.
- Review changed Markdown manually for stale paths, broken links, and accidental
  consumer-repo assumptions.

## Ruby Style

Ruby files in this repo use double-quoted strings. The RuboCop configuration
exists to keep editors and formatter hooks aligned with that style instead of
rewriting files to single quotes.

Prefer small, local Ruby changes. When a helper change needs tests, add or
update the focused helper test and run it directly in addition to `bin/validate`.

## Portability Rule

Shared files under `skills/` and `workflows/` must not hardcode consumer-repo
commands, labels, branch names, release trackers, package paths, or other local
policy. Refer to the consumer repo's `AGENTS.md` `## Agent Workflow
Configuration` seam by key instead.

For example, say "run the repo's pre-push local validation from the
`AGENTS.md` seam" instead of embedding a concrete command from one consumer
repo.

Repo-specific domain skills, destructive workflows, and local policy belong in
the consumer repo, not this shared pack.

## Adding A Skill

1. Create `skills/<skill-name>/SKILL.md`.
2. Add YAML frontmatter at the top. The `name:` value must exactly match the
   folder name, `description:` is required, and `argument-hint:` is optional.
3. Keep `SKILL.md` concise and portable. Move longer operating models into
   `workflows/` when the skill would otherwise become hard to scan.
4. Put skill-specific helper scripts and tests inside that skill folder. Use
   repo-wide `bin/` only for helpers shared across skills.
5. If you add a helper test such as `bin/*-test.rb` or `scripts/*.rb`, add it to
   the helper tests section of `bin/validate`.
6. Update the root `README.md` skill inventory when adding or removing a public
   skill.

Do not add README files inside individual skill folders.
