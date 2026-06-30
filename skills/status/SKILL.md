---
name: status
description: Report tight progress on the current work - done, in progress, blocked, and next - without starting new work. Use when asked for a status update or "where are we / anything needed from me".
---

# Status

Give a tight status update on the current work. **Do not start new work.**

Report:

- **Done** - what is complete and verified. Cite files, commits, or test results, and only claim
  "verified" if the check was actually run.
- **In progress** - what is mid-way through.
- **Blocked / needs input** - anything that genuinely needs a decision, credentials, or an external
  unblock. If nothing, say "nothing blocked".
- **Next** - the next one to three concrete steps, without starting them.

Keep it to roughly ten lines. If you are waiting on a long-running command or a background agent,
name it and the signal you are waiting for. Do not run another review or build solely to produce a
nicer status.
