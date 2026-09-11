# PR-Batch Unblock

## Unblock Block

Any conversation that stops non-clean — every final `Conversation status:
Follow-ups remain — <each exact action or blocker>.` — must let the operator act
without reading anything above the closing lines. Emit exactly one `Unblock:`
block as the last thing before that status line.

Closing order for the final user-visible message, with nothing between these:

1. The compact `Completed-batch audit:` receipt line, only when a completed-batch receipt is required and an existing verified receipt is available. When a completed-batch receipt is required but missing, emit no receipt line; carry the missing receipt only as a blocker and matching Unblock entry.
2. The `Unblock:` block, whenever the final status is `Follow-ups remain`.
3. The exact `Conversation status:` line.

Omit the block when the final status is `Conversation status: Ready for
archiving.`; that status is valid only when the normalized blocker union is
empty.

```text
Unblock:
1. [<you|agent|external>] <smallest next action or wait instruction> — <exact command, paste-ready prompt, URL, question, trigger, or clearing condition>
   Help: <a different way to clear this same blocker, or `none — <reason>`>
2. ...
```

Rules:

- One numbered entry per exact blocker in the same normalized blocker union rendered in the `Conversation status` line. Never drop a blocker, never add one that is missing from that union, and never merge two blockers into one entry.
- Order entries so an operator-owned action that would unblock other entries comes first; otherwise keep the status-line order. Mark the entry you promoted ahead of status-line order with `(reordered)` after the owner tag, so a skimming operator reads the deliberate promotion rather than a mismatch.
- `[you]` means the operator must act before anything else moves, including any manual resume prompt they have to paste after a runner restart. `[agent]` means this thread resumes on its own through a real trigger — name it, such as the 15-minute monitor wake or the bounded watch window. Never tag work `[agent]` when it cannot continue without the operator; manual resume instructions are always `[you]`. `[external]` means a check, bot, or third party is being waited on — name it, name the condition that clears it, and say plainly that no operator action is required.
- Each entry is the smallest next step, not the remaining plan. A `[you]` action is executable as written: an exact shell command, prompt, URL, or question. An `[agent]` entry names the exact trigger and clearing condition. An `[external]` entry gives the exact wait instruction and clearing condition and says no operator action is required.
- Each `Help:` line offers one genuinely different route to clearing that same blocker — waive, rerun, reassign, cancel the lane or batch, escalate to a named owner, or the exact skill or workflow section that performs it — or exactly `none — <reason>` when no alternative exists. Do not restate the primary action as its own help.
- An `UNKNOWN` fact is a blocker; its entry names the exact command or check that resolves it.
- Carry only blockers. Decisions, evidence, and FYI items stay in the handoff body above.
- When every entry is `[agent]` or `[external]`, still emit the block and say that waiting is the correct action, so the operator can tell that nothing is owed from them.

Worked example. The status line renders PR #124 first, but answering PR #123 with
`migrate` forces a re-push that restarts PR #124's checks, so the operator-owned
entry leads instead. Only the promoted entry carries `(reordered)`:

```text
Unblock:
1. [you] (reordered) Answer the storage-format question on PR #123 — https://github.com/OWNER/REPO/pull/123#discussion_r1 — reply `keep` or `migrate`
   Help: reply `defer` to record it as an accepted-deferral against PR #123 and keep that lane open on its existing PR; the question moves to a follow-up instead of blocking this batch.
2. [external] Wait for hosted CI `build` on PR #124 — it clears when the queued run finishes; no action needed from you
   Help: if it is still queued at the next monitor wake, cancel, wait for cancellation to complete, and retrigger with `gh run cancel --repo OWNER/REPO <run-id>` then `gh run watch --repo OWNER/REPO <run-id>` then `gh run rerun --repo OWNER/REPO <run-id>`; do not add `--exit-status` because cancellation is the expected conclusion, and `--failed` does not apply while a run is queued.
Conversation status: Follow-ups remain — PR #124 (pending): hosted CI `build`; PR #123 (open): answer storage-format question.
```
