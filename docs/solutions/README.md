# Workflow Lessons Library

`docs/solutions/` stores durable, portable workflow lessons for this source
pack. Add a lesson when repeated agent-workflow evidence shows a failure mode
and a reusable fix that belongs in shared process guidance.

Use a solution doc for lessons that are:

- portable across consumer repositories;
- grounded in observed workflow, validation, review, coordination, or trust
  behavior;
- specific enough that a future agent can search for the symptom and apply the
  resolution; and
- stable enough to outlive a single PR comment, issue comment, or memory note.

Do not use this library for consumer-domain policy, repo-specific command
choices, release tracker state, one-off session memory, or broad prose rules
that cannot be replayed. Consumer repositories still provide their commands and
policy through their own `AGENTS.md` seam.

Optional task-observer memory is a staging area for sanitized session
observations. Promote an observation into this library only after review shows
that the lesson meets the portability, evidence, specificity, and stability
rules above. Do not copy raw observation logs, proprietary context, or
repo-specific session state into `docs/solutions/`.

## Adding Or Refreshing A Lesson

Create one Markdown file under `docs/solutions/` with YAML frontmatter followed
by a concise body. Prefer refining an existing lesson when new evidence changes
the same reusable fix. Add a new lesson when the symptom, root cause, or
resolution is meaningfully different.

Required frontmatter fields for lesson files:

- `title`: human-readable lesson title.
- `date`: ISO 8601 date, `YYYY-MM-DD`.
- `category`: portable topic area, such as `coordination`, `trust`,
  `validation`, `review`, or `workflow`.
- `component`: shared pack surface most responsible for the lesson.
- `problem_type`: short stable handle for the failure mode.
- `symptoms`: list of observable signs.
- `root_cause`: short explanation of why the problem happens.
- `resolution`: reusable fix or operating rule.
- `related_files`: list of pack files that carry the workflow surface.
- `related_issues`: list of GitHub issue or PR URLs, or an empty list.

`bin/validate-solutions` validates lesson frontmatter and runs from
`bin/validate`. The README is the convention page and is not treated as a
lesson.
