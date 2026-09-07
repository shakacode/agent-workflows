## Goal Prompt Template

Keep this template aligned with the matching plan-to-goal prompt in the
resolved `pr-processing.md`, including the review/audit gate
paragraphs. The `Coordination:` line below intentionally points at the canonical
workflow rules instead of duplicating them.
`GMCC-v5` is a version key that pins drift, not an external-only pointer; its inline semantics remain normative when the workflow reference is missing or cannot autoload.
Use `HST-v1` from the canonical [Human-Status Translation Contract](../../../workflows/pr-processing.md#human-status-translation-contract) for every recurring wake or workflow-owned heartbeat.

Use this template when creating Codex goal text:

```text
Use $pr-batch to complete this batch with subagents.

Batch title: <PROJECT> <A?> <ID?> <MM-DD HH:MM> - <title>

Thread handle: <batch-short>-<lane>-<word>
Lane Card:claim/PR-open/block/cancel/final;route;holder/branch/PR/phase/URLs/UNKNOWN
Launch:<repo:<issue|pull-request>:N|repo:adhoc:date-slug>;ovr:n/a|name/auth/ref/task;none:reuse/create issue(auth/ask)+bind;invalid|dup|UNKNOWN:stop
PF:issue/PR=security;adhoc=trusted+task-bound+durable,no-target-security
Repo:OWNER/REPO
Objective:...
merge_authority:<none|ask|auto_merge_when_gates_pass>
Batch size target: <codex|claude|generic>;wave: <cap/items>
Coordinator model/effort preference: <model/class>/<effort>.
Observed host/model/effort: <host|UNKNOWN>/<model|UNKNOWN>/<effort|UNKNOWN>; host-only, no inference.
Manifest:pack_sha=<rev|UNKNOWN>;coordinator_preference=<model>/<effort>;lanes=<lane-id:dispatcher+preferred-route+observed-host/model/effort>,...;UNKNOWN=field;no guesses
Worker model/effort preferences: <initial model/class>/<effort> -> <lane ids>; escalation <model/class>/<effort> after MODEL_ESCALATION_REQUEST; max <N>.
Dispatch <lane>:<dispatcher>@<route>;fallback <dispatcher>@<route>->...|none;auth <y|n>;ordinary pending/active lifecycle
- Stage deps: v1 edit|validation_open|merge_order; missing/UNKNOWN/stale=>closed; combined-tip@repo-seam
GMCC-v5:CI@head/configured-reviewers pending|missing|untriaged|failed|threads open|UNKNOWN=>waiting-on-checks-or-review/NOT COMPLETE;poll/fix;auto-clear=>watch(same:0wake,delta:gates);fallback:4x15m+exp/4h|manual;stop clear/done/term/budget/user;noauth=>ready-no-merge-authority;ask=>own:walk|ext:user(merge|auth:add);blocked-user-input=>0retry/watch;auto=>exact verdict/head/sorted-gates/rollback;merge iff autonomous-merge-eligible|human-approved-for-current-head+durable-decision(proven+merge-authority);else ready-human-review-required|autonomous-merge-evidence-unknown;merge+close PR/target/issue.
HST-v1
Batch QA Lane:<owner/scope+evidence|none+rationale>
Scope:titles/deps/exclusions/owners;STAGE_DEPENDENCY_PLAN_PATH=<p>,STAGE_DEPENDENCY_PLAN_ID=<id>,live=<replay/ref>;ft=refs/paths/create/delete/rename/collisions/owner/serial/UNKNOWN
Items:
- Target:<repo:<issue|pull-request>:N URL|repo:adhoc:date-slug>
  Orig:<prompt|n/a>;ovr:<n/a|name/auth/ref/task>
  Goal:outcome
  Notes:scope/deps
  Done:req auth+PR/no-PR evidence|no-fix rationale
Execution rules:
Base:repo/AGENTS;fetch/prune origin;verify $pr-batch+workflow;unresolved=>UNKNOWN
- Resolve `$pr-batch`; autoload/self-contained: load persisted state before preflight; persist output before resume/launch; preflight issue/PR only.
- Routes advisory; observed host/model/effort host-only or UNKNOWN; checker independence/evidence mandatory.
- Dispatch: pending->persist/reissue token; active->no launch; input->decision; fence->stop/reconcile.
Current wave:each target/lane exactly once;one target/lane/worker;overlap=>integration advisory;deps/resv/UNKNOWN=>coord
Workers:paths=coord!=perm;path+resv;multi=>coord;stop:contradiction/ambig/scope-risk/verify-down;Verify live GitHub before edits;unverifiable=>UNKNOWN
- For coordination, respect coordination claims and dependencies: stable ids+heartbeats; register before launch when supported; claim refusal=>stop; push holder/generation check; known deps=>gate permissions; missing/UNKNOWN deps=>stop.
Apply Batch QA Lane;include QA Evidence
merge iff `merge_authority` is `auto_merge_when_gates_pass`|explicit merge approval;release+gates pass;record PR confidence
- ask=>$pr-walkthrough;gh=all/reply;live=opt;refresh;chg=>redo/stop;fail=>stop;ask iff same clean
Final:canonical closeout;links/tests/blockers/next/confidence/UNKNOWN/authority/QA/state

```
