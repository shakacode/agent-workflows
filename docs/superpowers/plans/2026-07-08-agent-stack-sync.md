# Agent Stack Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a hacker-friendly `agent-stack sync` command that keeps the three public agent repos in a canonical `~/src` layout and installs the local tools.

**Architecture:** `agent-workflows` owns the stack-level bootstrap command because it already owns host installs and upgrade helpers. The command clones or fast-forwards `agent-workflows`, `agent-coordination`, and `agent-coordination-dashboard`; creates compatibility symlinks under `~/codex/agent-repos`; installs `agent-coord`; installs workflow helpers; and refuses unsafe local states by default.

**Tech Stack:** Bash, Git CLI, existing `bin/install-agent-workflows`, existing `agent-coordination/bin/agent-coord bootstrap`, bash integration tests.

---

### Task 1: Add `agent-stack sync` Behavior

**Files:**
- Create: `/Users/justin/codex/agent-repos/agent-workflows/bin/agent-stack`
- Create: `/Users/justin/codex/agent-repos/agent-workflows/bin/agent-stack-test.bash`
- Modify: `/Users/justin/codex/agent-repos/agent-workflows/bin/validate`

- [ ] **Step 1: Write failing integration tests**

Create `bin/agent-stack-test.bash` with local bare-origin fixtures. Tests cover: first-run clone/install/symlink behavior, dirty repo refusal without `--force-stash`, and non-main branch refusal.

- [ ] **Step 2: Run tests to verify RED**

Run: `bash bin/agent-stack-test.bash`
Expected: fails because `bin/agent-stack` does not exist yet.

- [ ] **Step 3: Implement minimal command**

Create `bin/agent-stack` with a `sync` subcommand. It supports `--source-root`, `--compat-root`, `--host`, `--target`, `--mode`, `--agent-coord-install-dir`, `--force-stash`, `--replace-compat`, and `--no-fetch`.

- [ ] **Step 4: Run tests to verify GREEN**

Run: `bash bin/agent-stack-test.bash`
Expected: all tests pass.

- [ ] **Step 5: Add to validation**

Modify `bin/validate` to run `bash bin/agent-stack-test.bash`.

### Task 2: Install And Document The Stack Helper

**Files:**
- Modify: `/Users/justin/codex/agent-repos/agent-workflows/bin/install-agent-workflows`
- Modify: `/Users/justin/codex/agent-repos/agent-workflows/bin/install-agent-workflows-test.bash`
- Modify: `/Users/justin/codex/agent-repos/agent-workflows/README.md`
- Modify: `/Users/justin/codex/agent-repos/agent-workflows/docs/installation-and-upgrades.md`

- [ ] **Step 1: Write failing installer assertion**

Assert the installed target includes `<target>/bin/agent-stack`.

- [ ] **Step 2: Run installer tests to verify RED**

Run: `bash bin/install-agent-workflows-test.bash`
Expected: fails because `agent-stack` is not installed.

- [ ] **Step 3: Add `agent-stack` to installed helpers**

Update the installer helper list and help text.

- [ ] **Step 4: Run installer tests to verify GREEN**

Run: `bash bin/install-agent-workflows-test.bash`
Expected: all tests pass.

- [ ] **Step 5: Document canonical layout**

Update README and installation docs with `~/src` source repos, `~/.agent-workflows` runtime/config, compatibility symlinks, and `agent-stack sync`.

### Task 3: Validate, Publish, And Dogfood

**Files:**
- No additional files expected.

- [ ] **Step 1: Run full validation**

Run: `bin/validate`
Expected: `PASS agent-workflows validation`.

- [ ] **Step 2: Commit and open PR**

Run: `git add ... && git commit -m "Add agent stack sync helper"` then push and open a PR.

- [ ] **Step 3: Merge when gates pass**

Use `merge_authority: auto_merge_when_gates_pass`.

- [ ] **Step 4: Update M5 and M1**

Run `agent-stack sync` locally on M5 and via SSH on M1, using safe archive/manual handling for any stale non-main checkouts.
