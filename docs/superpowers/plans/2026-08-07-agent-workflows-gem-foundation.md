# Agent Workflows Gem Foundation Implementation Plan

> **Execution note:** Work task-by-task. Host-provided plan-execution or
> subagent capabilities are optional accelerators, not repository dependencies;
> when unavailable, follow the checked steps directly.

**Goal:** Establish the canonical `agent-workflows` gem, migrate the existing doctor subsystem as the first real implementation, and make every source-pack delivery mode install the wrapper and library atomically.

**Architecture:** The repository remains the source of truth. Conventional gem files under `lib/agent_workflows` and `exe` become canonical, while existing `bin` paths remain thin compatibility launchers. Copy installs select immutable complete runtime generations; symlink installs select the live editable clone through one pointer. Package tests prove source, installed-gem, flat-copy, symlink, and plugin-companion behavior.

**Tech Stack:** Ruby 3.2+, RubyGems, Bundler, Rake, Minitest, RuboCop, Bash installer tests.

## Global Constraints

- Public RubyGems package name is exactly `agent-workflows`.
- Ruby require path is exactly `agent_workflows`; top-level namespace is exactly `AgentWorkflows`.
- Ruby `>= 3.2`; CI tests Ruby 3.2 and the current project Ruby.
- Runtime dependencies are Ruby standard library only.
- Existing CLI paths, argv, stdout, stderr, JSON contracts, and exit codes remain stable.
- Source-pack installation remains offline after the source checkout is present; it never resolves an unpinned remote gem.
- Missing, partial, or incompatible installed libraries exit `64` with actionable diagnostics.
- Extraction does not change trust, mutation, timeout, or fail-closed policy.
- Package publication is not part of this plan.
- The development/release builder is pinned to Ruby `3.4.6`, RubyGems `3.6.9`,
  and Bundler `4.0.10`; Ruby `3.2` remains the supported runtime floor and a CI
  test target.
- Before every commit boundary below, run `bin/validate` after the focused tests
  and stop on any failure. The focused commands explain the changed behavior;
  they do not replace the repository gate required by `AGENTS.md`.
- Whenever a task adds or changes a manifest-listed file, stage the intended
  files and the owning gem or source-pack runtime manifest before running the
  final package tests or
  `bin/validate`. The tracked-file package gate inspects the index, so the
  sequence is: red test, implementation, `git add` exact intended paths,
  package tests, `bin/validate`, inspect `git diff --cached`, then commit. Never
  stage generated artifacts or unrelated worktree changes. Every staging recipe
  must expand to literal file or deletion paths; directory pathspecs, globs, and
  `git add -A` are invalid even when the worktree appears clean.

---

## File Structure

### New package files

- `agent-workflows.gemspec`: package identity, file manifest, metadata, Ruby floor, and executables.
- `agent-workflows.gem-manifest`: explicit, reviewed allowlist assigned to the
  gemspec's `spec.files`; it excludes source-pack-only wrappers and application
  files.
- `.ruby-version`: exact `3.4.6` development and release build interpreter; it does not change the gem's Ruby 3.2 floor.
- `Gemfile`: development dependencies through `gemspec`.
- `Rakefile`: focused unit, package, and aggregate test tasks.
- `lib/agent_workflows.rb`: canonical public require surface.
- `lib/agent_workflows/version.rb`: exposes `AgentWorkflows::VERSION`; a test keeps it equal to root `VERSION`.
- `lib/agent_workflows/result.rb`: typed command-result value carrying exit status, payload, and diagnostics.
- `lib/agent_workflows/process/runner.rb`: shared bounded argv/process-group adapter.
- `lib/agent_workflows/doctor/*.rb`: canonical doctor implementation.
- `lib/agent_workflows/distribution/install_ownership.rb`: installer tree digest, marker, and ownership CLI behavior.
- `lib/agent_workflows/cli/workflows_doctor.rb`: component-doctor CLI adapter.
- `lib/agent_workflows/cli/stack_doctor.rb`: aggregate stack-doctor CLI adapter.
- `exe/agent-workflows-doctor`: RubyGems executable.
- `exe/agent-stack-doctor`: RubyGems executable.
- `test/gem/*_test.rb`: direct tests for package primitives and doctor classes.
- `test/packaging/*_test.rb`: built-gem and installed-command tests.

### Compatibility and distribution files

- `bin/agent-workflows-doctor`: thin source-pack launcher.
- `bin/agent-stack-doctor`: thin source-pack launcher.
- `agent-workflows.runtime-manifest`: created with the Task 5 cutover and read
  only by source-pack installers and launchers from the selected copy generation or live
  symlink source so partial application-library installs fail before Ruby loads
  them. It includes the canonical library plus source-pack wrappers and resources
  that are intentionally absent from the gem.
- `bin/agent_doctor/*.rb`: during the pilot, moved doctor files become thin
  compatibility bodies until Task 5 makes the canonical library installable;
  Task 6 removes those bodies, while the three autonomous-merge policy files
  remain until the later merge-domain task.
- `bin/install-agent-workflows`: selects `lib/agent_workflows` atomically with wrappers.
- `bin/install-agent-workflows-test.bash`: tests all delivery layouts and failure cases.
- `bin/agent_stack/installers.bash`: installs the shared library for colocated stack commands.
- `bin/agent_stack/module_install.bash`: treats wrappers and library as one managed module set.
- `test/agent_doctor/*`: moved or rewritten to require canonical gem paths.
- `bin/validate`: runs gem, package, installer, and existing repository gates.
- `.github/workflows/validate.yml`: tests the supported Ruby matrix.
- `.rubocop-gem.yml`: inherits repository style and enables stricter metrics for canonical gem code.
- `bin/lint`: runs the stricter config for `lib/**/*.rb`, `exe/*`, and new gem tests after repository lint.
- `README.md`, `docs/installation-and-upgrades.md`, `CHANGELOG.md`: document gem identity and source-pack relationship.

### Interfaces fixed by this plan

```ruby
module AgentWorkflows
  VERSION = "0.1.0"

  Result = Data.define(:exit_status, :payload, :diagnostics)
end

AgentWorkflows::CLI::WorkflowsDoctor.start(
  argv,
  env:,
  input:,
  output:,
  error:
) # => Integer

AgentWorkflows::CLI::StackDoctor.start(
  argv,
  env:,
  input:,
  output:,
  error:
) # => Integer
```

Ruby 3.2 provides `Data`. Every `Result` instance validates `exit_status` as an
integer and freezes the diagnostics collection supplied by package code before
return.

### Task 1: Add the gem skeleton and package identity

**Files:**

- Create: `agent-workflows.gemspec`
- Create: `agent-workflows.gem-manifest`
- Create: `Gemfile`
- Create: `Gemfile.lock`
- Create: `Rakefile`
- Create: `.ruby-version`
- Create: `lib/agent_workflows.rb`
- Create: `lib/agent_workflows/version.rb`
- Create: `test/gem/version_test.rb`
- Create: `test/packaging/gemspec_test.rb`
- Modify: `.gitignore`

**Interfaces:**

- Consumes: root `VERSION`, `LICENSE`, `README.md`, `CHANGELOG.md`.
- Produces: `AgentWorkflows::VERSION`; buildable `agent-workflows-VERSION.gem`.

- [ ] **Step 1: Write the version and gemspec tests**

```ruby
# test/gem/version_test.rb
require "minitest/autorun"
require_relative "../../lib/agent_workflows"

class AgentWorkflowsVersionTest < Minitest::Test
  def test_version_matches_root_version
    expected = File.read(File.expand_path("../../VERSION", __dir__), encoding: "UTF-8").strip
    assert_equal expected, AgentWorkflows::VERSION
  end
end
```

```ruby
# test/packaging/gemspec_test.rb
require "minitest/autorun"
require "rubygems"

class AgentWorkflowsGemspecTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SPEC = Gem::Specification.load(File.join(ROOT, "agent-workflows.gemspec"))

  def test_canonical_identity
    assert_equal "agent-workflows", SPEC.name
    assert_equal Gem::Requirement.new(">= 3.2"), SPEC.required_ruby_version
    assert_empty SPEC.runtime_dependencies
    assert_equal "true", SPEC.metadata.fetch("rubygems_mfa_required")
    assert_equal "https://rubygems.org", SPEC.metadata.fetch("allowed_push_host")
  end

  def test_manifest_has_no_repository_only_tests
    assert_includes SPEC.files, "lib/agent_workflows.rb"
    expected = File.readlines(File.join(ROOT, "agent-workflows.gem-manifest"), chomp: true, encoding: "UTF-8")
    assert_equal expected.reject(&:empty?).sort, SPEC.files.sort
    refute expected.any? { |path| path.start_with?("/", "../") || path.include?("/../") }
    assert_equal expected.uniq, expected
    assert_equal expected.sort, expected
    refute SPEC.files.any? { |path| path.start_with?("test/") }
    refute SPEC.files.any? { |path| path.start_with?("docs/superpowers/") }
  end
end
```

- [ ] **Step 2: Run the tests and verify the missing package fails**

Run:

```bash
ruby test/gem/version_test.rb
ruby test/packaging/gemspec_test.rb
```

Expected: both fail because the canonical library and gemspec do not exist.

- [ ] **Step 3: Add the canonical require and version**

```ruby
# lib/agent_workflows/version.rb
module AgentWorkflows
  VERSION = "0.1.0"
end
```

```ruby
# lib/agent_workflows.rb
require_relative "agent_workflows/version"

module AgentWorkflows
end
```

- [ ] **Step 4: Add the package definition**

Create `agent-workflows.gemspec` with:

```ruby
# frozen_string_literal: true

require_relative "lib/agent_workflows/version"

root = __dir__
manifest = File.join(root, "agent-workflows.gem-manifest")
package_files = File.readlines(manifest, chomp: true, encoding: "UTF-8").reject(&:empty?)
raise "Unsafe agent-workflows manifest" unless package_files == package_files.sort &&
                                               package_files.uniq == package_files &&
                                               package_files.none? { |path| path.start_with?("/", "../") || path.include?("/../") }

def resolved_manifest_entry(root, relative_path)
  parts = relative_path.split("/", -1)
  return if parts.empty? || parts.any? { |part| part.empty? || part == "." || part == ".." }

  root = File.realpath(root)
  current = root
  parts.each_with_index do |part, index|
    current = File.join(current, part)
    stat = File.lstat(current)
    return if stat.symlink?
    return unless index == parts.length - 1 ? stat.file? : stat.directory?
  end
  resolved = File.realpath(current)
  resolved if resolved.start_with?("#{root}#{File::SEPARATOR}")
rescue Errno::ENOENT, Errno::ELOOP
  nil
end

resolved_package_files = package_files.map { |path| resolved_manifest_entry(root, path) }
raise "Missing, duplicate, or non-regular agent-workflows manifest entry" unless resolved_package_files.none?(&:nil?) &&
                                                                               resolved_package_files.uniq == resolved_package_files

Gem::Specification.new do |spec|
  spec.name = "agent-workflows"
  spec.version = AgentWorkflows::VERSION
  spec.authors = ["ShakaCode"]
  spec.summary = "Portable, reviewable agent workflow command-line tools"
  spec.description = "Ruby command implementations for the ShakaCode Agent Workflows source pack."
  spec.homepage = "https://github.com/shakacode/agent-workflows"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }
  spec.files = package_files
  spec.bindir = "exe"
  spec.executables = package_files.grep(%r{\Aexe/[^/]+\z}).map { |path| File.basename(path) }.sort
  spec.require_paths = ["lib"]
end
```

Create `agent-workflows.gem-manifest` with the exact initial gem contents,
including the manifest itself, `LICENSE`, `README.md`, `CHANGELOG.md`, and every
library or packaging file introduced by this task. Every later task updates this
checked-in allowlist in the same commit as new package files. Never generate the
release manifest from the dirty worktree. Packaging tests require every entry
to be tracked by Git with an index type for a regular file, reject untracked,
duplicate, symlink, or gitlink entries, and assert the built gem contains the
license, README, and changelog. Construct temporary in-tree and out-of-tree
symlink entries at both the final component and a parent directory to prove
gemspec loading and `gem build` fail before packaging any linked bytes.

Create `Gemfile`:

```ruby
source "https://rubygems.org"

gem "minitest", require: false
gem "rake", require: false
gemspec
```

Create `.ruby-version` containing exact `3.4.6`. Generate `Gemfile.lock` with
Ruby 3.4.6, RubyGems 3.6.9, and Bundler 4.0.10, and require the lockfile's
`BUNDLED WITH` value to equal `4.0.10`. Add packaging assertions for the exact
development builder while retaining `required_ruby_version >= 3.2`. Before the
build and again in the release job, independently assert `ruby --version` is
3.4.6, `gem --version` is 3.6.9, and `bundle --version` is 4.0.10; do not infer
the RubyGems version from `Gemfile.lock`. CI later proves runtime behavior on the
floor independently.

Create `Rakefile` with `require "bundler/gem_tasks"`, named `test:gem` and
`test:packaging` Minitest file-list tasks, and an aggregate `test` task. Add a
test that `rake -T` exposes the Bundler build and release tasks required by the
planned `rubygems/release-gem` workflow. Run `bundle lock`, commit
`Gemfile.lock`, and prove `bundle exec rake -T` works in a clean bundle rather
than relying on globally installed Rake. Add `/pkg/` to `.gitignore`.

- [ ] **Step 5: Build and inspect the package**

Stage the exact files listed for this task before invoking the tracked-file
package assertion:

```bash
git add -- .gitignore .ruby-version Gemfile Gemfile.lock Rakefile \
  agent-workflows.gemspec agent-workflows.gem-manifest \
  lib/agent_workflows.rb lib/agent_workflows/version.rb \
  test/gem/version_test.rb test/packaging/gemspec_test.rb
```

Run:

```bash
mkdir -p pkg
gem build agent-workflows.gemspec --output pkg/agent-workflows.gem
gem specification pkg/agent-workflows.gem --yaml
ruby test/gem/version_test.rb
ruby test/packaging/gemspec_test.rb
```

Expected: build succeeds; name is `agent-workflows`; version matches `VERSION`; Ruby requirement is `>= 3.2`; executables are empty until Task 4.

- [ ] **Step 6: Commit the package skeleton**

```bash
git diff --cached --check
git commit -m "build: add agent-workflows gem skeleton"
```

### Task 2: Add typed command results and package-scoped quality rules

**Files:**

- Create: `lib/agent_workflows/result.rb`
- Create: `lib/agent_workflows/errors.rb`
- Create: `lib/agent_workflows/process/runner.rb`
- Create: `test/gem/result_test.rb`
- Create: `test/gem/process/runner_test.rb`
- Modify: `lib/agent_workflows.rb`
- Modify: `agent-workflows.gem-manifest`
- Create: `.rubocop-gem.yml`
- Modify: `bin/lint`
- Modify: `bin/lint-test.rb`

**Interfaces:**

- Consumes: `AgentWorkflows` namespace from Task 1.
- Produces: `AgentWorkflows::Result`, `AgentWorkflows::UsageError`,
  `AgentWorkflows::UnableToRunError`, and the cross-domain
  `AgentWorkflows::Process::Runner`.

- [ ] **Step 1: Write result validation tests**

```ruby
require "minitest/autorun"
require_relative "../../lib/agent_workflows"

class AgentWorkflowsResultTest < Minitest::Test
  def test_result_keeps_explicit_exit_status_and_payload
    result = AgentWorkflows::Result.new(exit_status: 2, payload: {"status" => "failed"}, diagnostics: ["missing"])
    assert_equal 2, result.exit_status
    assert_equal "failed", result.payload.fetch("status")
  end

  def test_result_rejects_non_integer_exit_status
    assert_raises(ArgumentError) do
      AgentWorkflows::Result.new(exit_status: "2", payload: nil, diagnostics: [])
    end
  end
end
```

- [ ] **Step 2: Add runner characterization and verify focused failures**

Copy the exact spawn-error, bounded stdout/stderr, timeout, TERM/KILL escalation,
process-group, and descendant-cleanup assertions from the existing doctor
runner test into `test/gem/process/runner_test.rb`, targeting
`AgentWorkflows::Process::Runner`.

Run:

```bash
ruby test/gem/result_test.rb
ruby test/gem/process/runner_test.rb
```

Expected: `NameError` for the new canonical constants.

- [ ] **Step 3: Implement the result and errors**

```ruby
# lib/agent_workflows/result.rb
module AgentWorkflows
  Result = Data.define(:exit_status, :payload, :diagnostics) do
    def initialize(exit_status:, payload: nil, diagnostics: [])
      raise ArgumentError, "exit_status must be an Integer" unless exit_status.is_a?(Integer)

      super(exit_status:, payload:, diagnostics: diagnostics.freeze)
    end
  end
end
```

```ruby
# lib/agent_workflows/errors.rb
module AgentWorkflows
  class Error < StandardError; end
  class UsageError < Error; end
  class UnableToRunError < Error; end
end
```

Move the reusable implementation behavior, not its doctor namespace, into
`AgentWorkflows::Process::Runner`. It accepts argv arrays only and preserves the
characterized timeout, output ceilings, signal escalation, process-group, and
descendant-cleanup contracts. Require all three files from
`lib/agent_workflows.rb` and add them to `agent-workflows.gem-manifest` in
deterministic sorted order. The legacy doctor runner body remains unchanged
until the source-pack cutover.

- [ ] **Step 4: Scope RuboCop metrics to canonical gem code**

Create `.rubocop-gem.yml` inheriting `.rubocop.yml`, override
`AllCops/TargetRubyVersion` to the gem's declared floor of 3.2, then explicitly
enable the design thresholds: line length 120, method length 30, cyclomatic
complexity 8, perceived complexity 9, parameter lists 5, class length 250, and
module length 300. Update `bin/lint` to run a second RuboCop invocation with
`--config .rubocop-gem.yml` over `lib/**/*.rb`, `exe/*`,
`test/gem/**/*_test.rb`, `test/packaging/**/*_test.rb`, the gemspec, Rakefile,
and Gemfile. Extend `bin/lint-test.rb` to assert that this strict invocation is
present, targets Ruby 3.2, and does not include legacy command bodies.

- [ ] **Step 5: Run focused tests and lint**

Run:

```bash
ruby test/gem/result_test.rb
ruby test/gem/process/runner_test.rb
rubocop "_$(tr -d '[:space:]' < .rubocop-version)_" --config .rubocop-gem.yml lib test/gem test/packaging agent-workflows.gemspec Rakefile Gemfile
```

Expected: PASS with no offenses.

- [ ] **Step 6: Commit the package primitives**

```bash
git add -- .rubocop-gem.yml agent-workflows.gem-manifest bin/lint \
  bin/lint-test.rb lib/agent_workflows.rb lib/agent_workflows/errors.rb \
  lib/agent_workflows/result.rb lib/agent_workflows/process/runner.rb \
  test/gem/result_test.rb test/gem/process/runner_test.rb
git commit -m "refactor: add typed agent workflows command results"
```

### Task 3: Add the doctor domain in the canonical namespace

**Files:**

- Create: `lib/agent_workflows/doctor/*.rb`
- Create: `lib/agent_workflows/distribution/install_ownership.rb`
- Create: `test/gem/doctor/*_test.rb`
- Create: `test/gem/distribution/install_ownership_test.rb`
- Modify: `lib/agent_workflows.rb`
- Modify: `agent-workflows.gem-manifest`
- Retain unchanged temporarily: every existing `bin/agent_doctor/*.rb` body and
  its legacy tests until the atomic source-pack cutover in Task 5.

**Interfaces:**

- Consumes: existing behavior from `bin/agent_doctor/*.rb`; result/errors from Task 2.
- Produces:
  `AgentWorkflows::Doctor::{Configuration,Contract,Orchestrator,Renderer,Sanitizer,SourceChecks,TimeoutBudget,WorkflowsComponent}`
  using the shared `AgentWorkflows::Process::Runner` from Task 2, plus
  `AgentWorkflows::Distribution::InstallOwnership` for source-pack tree
  digests, ownership markers, and its compatibility CLI.

- [ ] **Step 1: Add direct canonical-namespace tests for one pure and one side-effecting class**

Copy the behavioral assertions from `test/agent_doctor/contract_test.rb` and
`test/agent_doctor/workflows_component_test.rb` into new tests that require
`agent_workflows`, then replace every `AgentDoctor::` reference with
`AgentWorkflows::Doctor::`. Inject `AgentWorkflows::Process::Runner` where a
real runner is required.

- [ ] **Step 2: Run the new tests and verify namespace failure**

Run:

```bash
ruby -Ilib test/gem/doctor/contract_test.rb
ruby -Ilib test/gem/doctor/workflows_component_test.rb
```

Expected: `NameError` for `AgentWorkflows::Doctor`.

- [ ] **Step 3: Move files without redesigning behavior**

Copy the doctor support files `configuration.rb`, `contract.rb`,
`orchestrator.rb`, `renderer.rb`, `sanitizer.rb`, `source_checks.rb`,
`timeout_budget.rb`, and `workflows_component.rb` to the same basenames under
`lib/agent_workflows/doctor/`. Wrap every class/module in:

```ruby
module AgentWorkflows
  module Doctor
    # existing class or module body
  end
end
```

Move the behavior from `bin/agent_doctor/install_ownership.rb` directly to
`lib/agent_workflows/distribution/install_ownership.rb` under
`AgentWorkflows::Distribution::InstallOwnership`; it is installer ownership,
not doctor diagnosis. Copy its existing tests to the matching distribution
test path and add an explicit `.start(argv)` adapter so later callers do not
depend on a required file's `$PROGRAM_NAME == __FILE__` guard.

Convert sibling `require_relative` calls to the new sibling paths and inject the
shared process runner. Leave
`autonomous_merge_policy.rb`, `autonomous_merge_policy_globs.rb`, and
`autonomous_merge_policy_yaml.rb` in `bin/agent_doctor` until the later merge
domain task moves them atomically with their runtime-trust manifests and
callers. Preserve every old implementation body, including `workflows_cli.rb`,
`stack_cli.rb`, and the executable behavior in `install_ownership.rb`, through
Task 4. Replacing them with shims here would break existing copy,
plugin-companion, and stack installations because their installer does not ship
`lib` yet. Add every new canonical library file to
`agent-workflows.gem-manifest` in the same commit.

- [ ] **Step 4: Update all doctor tests to canonical requires**

Keep the existing `test/agent_doctor/*_test.rb` suite pointed at the unchanged
legacy bodies. Add equivalent canonical tests under `test/gem/doctor` and
`test/gem/distribution`; preserve test names and assertions so review can
distinguish copied behavior from redesign. This temporary duplication is
deliberate and ends only after the installer cutover proves canonical bytes are
present everywhere.

- [ ] **Step 5: Run every doctor test**

Run:

```bash
for test_file in test/agent_doctor/*_test.rb test/gem/doctor/*_test.rb test/gem/distribution/*_test.rb; do ruby -Ilib "$test_file" || exit; done
```

Expected: all tests pass with unchanged assertions.

- [ ] **Step 6: Commit the doctor library move**

```bash
git add -- agent-workflows.gem-manifest lib/agent_workflows.rb \
  lib/agent_workflows/doctor/configuration.rb \
  lib/agent_workflows/doctor/contract.rb \
  lib/agent_workflows/doctor/orchestrator.rb \
  lib/agent_workflows/doctor/renderer.rb \
  lib/agent_workflows/doctor/sanitizer.rb \
  lib/agent_workflows/doctor/source_checks.rb \
  lib/agent_workflows/doctor/timeout_budget.rb \
  lib/agent_workflows/doctor/workflows_component.rb \
  lib/agent_workflows/distribution/install_ownership.rb \
  test/gem/doctor/configuration_test.rb test/gem/doctor/contract_test.rb \
  test/gem/doctor/orchestrator_test.rb test/gem/doctor/renderer_test.rb \
  test/gem/doctor/sanitizer_test.rb test/gem/doctor/source_checks_test.rb \
  test/gem/doctor/timeout_budget_test.rb \
  test/gem/doctor/workflows_component_test.rb \
  test/gem/distribution/install_ownership_test.rb
git commit -m "refactor: add canonical agent workflows doctor library"
```

### Task 4: Add gem CLIs and thin compatibility launchers

**Files:**

- Create: `lib/agent_workflows/cli/workflows_doctor.rb`
- Create: `lib/agent_workflows/cli/stack_doctor.rb`
- Create: `exe/agent-workflows-doctor`
- Create: `exe/agent-stack-doctor`
- Retain unchanged temporarily: `bin/agent-workflows-doctor`,
  `bin/agent-stack-doctor`, `bin/agent_doctor/workflows_cli.rb`, and
  `bin/agent_doctor/stack_cli.rb`.
- Modify: `lib/agent_workflows.rb`
- Modify: `agent-workflows.gem-manifest`
- Create: `test/packaging/executable_test.rb`

**Interfaces:**

- Consumes: `AgentWorkflows::Doctor` classes from Task 3.
- Produces: the two `CLI.start` signatures fixed above and the two gem
  executable paths; source-pack paths remain on their complete legacy bodies
  until Task 5 can install library and launcher together.

- [ ] **Step 1: Extend launcher tests to cover canonical library failures**

Add package-executable cases asserting that an installed gem without
`agent_workflows.rb` or a required nested file fails cleanly, and that complete
isolated gem installs succeed without the source checkout. Record the
source-pack missing-manifest, partial-library, and unsafe-manifest acceptance
cases in Task 5; do not replace the live source-pack launcher yet.

- [ ] **Step 2: Run launcher tests and verify failure against the old adjacent-module contract**

Run: `ruby test/packaging/executable_test.rb`

Expected: canonical gem executable cases fail because the executables do not
exist yet. Existing legacy launcher tests continue to pass.

- [ ] **Step 3: Implement injectable CLI adapters**

Move the current option parsing and rendering entry logic from
`AgentDoctor::WorkflowsCLI` and `AgentDoctor::StackCLI` into the two canonical
CLI classes. Keep domain calls delegated to doctor objects. Require both CLI
adapter files from `lib/agent_workflows.rb` so a cold
`require "agent_workflows"` defines both constants. Each `.start` rescues only
`OptionParser::ParseError`, `AgentWorkflows::UsageError`, and
`AgentWorkflows::UnableToRunError`, writes a concise diagnostic to `error`, and
returns `64`. Make every doctor configuration/input error subclass the matching
top-level error (or normalize it to that error at the domain boundary); do not
define a parallel `AgentWorkflows::Doctor::Configuration::UsageError` that the
CLI rescue cannot catch. Add malformed dashboard URL, host, and path cases that
prove one diagnostic, no backtrace, and exit `64`.

Keep the two old CLI implementation files unchanged. Canonical adapters must
match their behavior through differential tests, but no installed legacy path
may require the uninstalled canonical library before Task 5.

- [ ] **Step 4: Add gem executables and specify the later source-pack launcher**

Defer changing both root launchers to Task 5. Specify their cutover contract
now: they read the selected runtime root's exact
`agent-workflows.runtime-manifest`, reject
absolute or parent-traversing entries, and verify every listed `lib/` file is a
regular file before loading Ruby. Before touching `Data` or requiring any gem
code, a stdlib-free launcher check parses `RUBY_VERSION` and rejects anything
older than 3.2 with one actionable diagnostic and exit `64`. Unit-test the
predicate with 2.7, 3.1, 3.2, and 4.0 strings, and run a negative launcher
contract under an available pre-3.2 Ruby in CI so the no-backtrace behavior is
proved in the real interpreter. The source-pack launchers verify the receipt's
expected package version against the manifest-selected `version.rb`, prepend
only the selected runtime root's exact `lib` to `$LOAD_PATH`, require
`agent_workflows`, explicitly verify the expected version and relevant CLI
constant are defined, and call `.start`. Manifest, `LoadError`, Ruby-version,
missing-constant, and package-version failures produce one diagnostic and exit
`64` without a backtrace. Syntax errors and unrelated runtime exceptions are not
broadly rescued. The launchers do not search GEM paths or another checkout.

Both `exe/*` files use:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

ruby_major, ruby_minor = RUBY_VERSION.split(".").first(2).map(&:to_i)
if ruby_major < 3 || (ruby_major == 3 && ruby_minor < 2)
  warn "agent-workflows requires Ruby 3.2 or newer"
  exit 64
end

begin
  require "agent_workflows"
rescue LoadError => error
  warn "agent-workflows installation is incomplete: #{error.path || error.message}"
  exit 64
end

unless defined?(AgentWorkflows::VERSION) &&
    defined?(AgentWorkflows::CLI::WorkflowsDoctor)
  warn "agent-workflows installation has incompatible package bytes"
  exit 64
end

exit AgentWorkflows::CLI::WorkflowsDoctor.start(
  ARGV, env: ENV, input: $stdin, output: $stdout, error: $stderr
)
```

Use `StackDoctor` for the second executable. Keep this guard free of package
syntax or constants so it runs before any partial or too-new library is parsed.
RubyGems selects the installed package version for `exe/*`; the independent
package-version check belongs to the source-pack receipt/manifest boundary
rather than being inferred from a gem executable's own loaded constants. Tests
remove the root require and each nested required file in turn, remove the
expected CLI and version constants, and inject a source-pack package-version
mismatch; each documented compatibility failure requires one actionable
diagnostic, no backtrace, and exit `64`. A syntax-error fixture proves unrelated
parse failures are not converted into compatibility errors. Add both executables
and all new CLI library files to `agent-workflows.gem-manifest` in deterministic
sorted order.

- [ ] **Step 5: Test all launch paths**

Run:

```bash
ruby test/agent_doctor/launcher_test.rb
ruby -Ilib exe/agent-workflows-doctor --help
ruby -Ilib exe/agent-stack-doctor --help
gem build agent-workflows.gemspec --output pkg/agent-workflows.gem
ruby test/packaging/executable_test.rb
```

Expected: legacy source-pack and canonical gem paths emit their established help
text and exit successfully; isolated gem missing-library cases fail cleanly.

- [ ] **Step 6: Commit the launchers**

```bash
git add -- agent-workflows.gemspec agent-workflows.gem-manifest \
  exe/agent-workflows-doctor exe/agent-stack-doctor \
  lib/agent_workflows.rb lib/agent_workflows/cli/workflows_doctor.rb \
  lib/agent_workflows/cli/stack_doctor.rb \
  test/packaging/executable_test.rb
git commit -m "feat: expose doctor commands through agent workflows gem"
```

### Task 5: Make source-pack installation atomic across wrappers and library

**Files:**

- Modify: `bin/install-agent-workflows`
- Modify: `bin/install-agent-workflows-test.bash`
- Modify: `bin/agent-workflows-doctor`
- Modify: `bin/agent-stack-doctor`
- Modify: `bin/agent_stack/installers.bash`
- Modify: `bin/agent_stack/module_install.bash`
- Create: `agent-workflows.runtime-manifest`
- Modify: `test/agent_doctor/launcher_test.rb`
- Modify: `test/agent_stack/module_install_test.bash`
- Modify: `test/agent_stack/doctor_install_test.bash`
- Modify: `docs/installation-and-upgrades.md`

**Interfaces:**

- Consumes: canonical `lib/agent_workflows` and root wrappers.
- Produces in copy mode: immutable complete runtimes under
  `<target>/.agent-workflows-generations/<runtime-digest>/`, one atomic
  `<target>/.agent-workflows-current` pointer, and fixed installed launcher
  paths. Produces in symlink mode: fixed launchers plus one atomically installed
  pointer to the live source clone, preserving the documented edit-in-place
  development workflow.

- [ ] **Step 1: Add failing copy and symlink layout tests**

For copy mode, assert regular files exist beneath the selected immutable
generation, that their SHA-256 digests match source, and that the installed
doctor succeeds after the source checkout is renamed. For symlink mode, assert
that the single current pointer resolves to the editable clone, then change a
canonical Ruby file in the fixture clone and prove the next invocation observes
the edit without reinstalling. Repeat for flat and plugin-companion delivery.

Add copy-mode fault-injection cases while staging, before and after the single
current pointer swap, during initial fixed-launcher migration, and during final
validation. Every invocation must observe either the prior complete generation
or the new complete generation. For symlink mode, fault injection must preserve
the prior complete live-source pointer or select the new complete source root;
editing files inside the selected developer clone is intentionally outside the
installer transaction. Every installer failure preserves or restores the prior
pointer, launchers, ownership markers, and metadata.

- [ ] **Step 2: Add failing partial-install and version-mismatch tests**

In copy mode, delete one installed library file and assert the command exits `64` without
searching the source checkout. Replace installed `version.rb` with another
same-length, same-version payload and separately alter another library file;
assert the launcher recomputes and rejects the recorded manifest/library-tree
digest before requiring any package Ruby. Also replace `version.rb` with another
version and assert status/doctor reports a version mismatch without mutation.

- [ ] **Step 3: Run focused installer tests and verify failure**

Run:

```bash
bash bin/install-agent-workflows-test.bash
bash test/agent_stack/module_install_test.bash
bash test/agent_stack/doctor_install_test.bash
```

Expected: new library-layout cases fail before installer changes.

- [ ] **Step 4: Extend installer staging and ownership**

Create `agent-workflows.runtime-manifest` as the sorted, explicit source-pack
allowlist for the canonical library, source-pack wrappers, and required runtime
resources. It is separate from `agent-workflows.gem-manifest`; source-pack-only
paths never enter `spec.files`, and the gem manifest never substitutes for
source-pack completeness validation.

In copy mode, stage the complete runtime manifest, library tree, executable wrappers,
resources, and generation-local receipt under a temporary directory. The
receipt records `ruby_package_name`, `ruby_package_version`, the full source
revision, and sorted path/mode/SHA-256 entries; its digest names the immutable
generation. Validate every entry, then atomically rename the complete directory
to `.agent-workflows-generations/<runtime-digest>`. Fixed installed launchers
resolve `.agent-workflows-current` exactly once to an immutable generation,
validate that generation's receipt and full library-tree digest before
requiring Ruby, and never fall back to a gem or source checkout. Retain the
prior generation while any invocation can still use it.

Installer and stack-sync ownership checks now invoke
`AgentWorkflows::Distribution::InstallOwnership` from the selected complete
runtime. Keep the old `bin/agent_doctor/install_ownership.rb` body intact until
this atomic cutover, then replace its remaining repository caller with the
canonical distribution adapter before Task 6 removes the legacy file. Run the
existing marker/digest compatibility corpus against both implementations before
the cutover and only the canonical implementation afterward.

For the first migration, create and validate the complete generation and
current pointer before atomically replacing each legacy launcher with its fixed
trampoline; an invocation therefore opens either the complete legacy launcher
or the complete new trampoline. After migration, publish an upgrade with one
atomic relative-symlink replacement of `.agent-workflows-current`; do not
promote manifest, library, metadata, or wrappers as separate live paths.

In symlink mode, preserve the existing live-development contract: atomically
point `.agent-workflows-current` at the canonical root of the explicitly chosen
editable clone. Fixed launchers resolve that root once, validate safe manifest
paths, required-file presence, and package/Ruby compatibility, then load the
live files; they do not compare content against a frozen install digest. Record
the observed revision for status only and report later source edits as a dirty
development checkout, not corruption. Refuse unmanaged conflicts, unsafe links,
and destination ownership mismatches using the current no-follow checks.
Serialize installers with the existing lock; rollback removes an unselected
copy generation or restores the prior pointer/launcher on an initial-migration
failure.

- [ ] **Step 5: Update stack sync**

Teach the stack module installer that doctor wrappers select one complete
runtime containing the matching `lib/agent_workflows` module. Copy-mode,
adoption, and status checks verify the current pointer, receipt, and runtime
digest before mutation. Symlink-mode checks verify the canonical live-source
pointer, manifest completeness, compatibility, and dirty-checkout status
without rejecting intentional edits. Preserve unrelated files and the existing
`.agent-stack-managed` and `.agent-workflows-managed` ownership markers.

- [ ] **Step 6: Run installer and rollback suites**

Run the three focused scripts from Step 3 and then `bash bin/agent-stack-test.bash`.

Expected: copy, symlink, flat, plugin-companion, relocated-source, partial-install, mismatch, upgrade, and rollback cases pass.

- [ ] **Step 7: Commit atomic distribution support**

```bash
git add -- agent-workflows.runtime-manifest bin/install-agent-workflows \
  bin/install-agent-workflows-test.bash bin/agent-workflows-doctor \
  bin/agent-stack-doctor bin/agent_stack/installers.bash \
  bin/agent_stack/module_install.bash test/agent_doctor/launcher_test.rb \
  test/agent_stack/module_install_test.bash \
  test/agent_stack/doctor_install_test.bash \
  docs/installation-and-upgrades.md
git commit -m "feat: install agent workflows Ruby library atomically"
```

### Task 6: Remove the legacy doctor implementation tree

**Files:**

- Delete: migrated doctor and CLI files under `bin/agent_doctor/`.
- Retain: `bin/agent_doctor/autonomous_merge_policy*.rb` for the later
  merge-domain cutover.
- Modify: every remaining `require_relative` reference returned by the discovery command below.
- Modify: installer ownership and migration tests that refer to the old directory.
- Modify: `README.md`, `docs/installation-and-upgrades.md`.

**Interfaces:**

- Consumes: canonical doctor library and installed layouts from Tasks 3-5.
- Produces: one doctor implementation tree with no runtime fallback; the three
  autonomous-merge policy files remain temporarily for the later merge-domain
  cutover.

- [ ] **Step 1: Prove all remaining callers before deletion**

Run:

```bash
rg -n 'agent_doctor|AgentDoctor|AutonomousMergePolicy' --glob '*.rb' --glob 'bin/*' --glob 'bin/**/*.bash' --glob 'test/**/*'
```

Classify every hit as canonical library use, compatibility test fixture, documentation, or stale dependency. Convert stale dependencies before deleting files.

- [ ] **Step 2: Delete the old implementation and run focused suites**

Remove the migrated doctor and CLI files from `bin/agent_doctor`, but retain the
three `autonomous_merge_policy*.rb` files until the domain-extraction plan's
merge task. Run doctor, installer, stack, autonomous-merge policy, and
seam-doctor tests. Expected: doctor and CLI callers have no `require_relative`
references into the retained policy location; merge callers and runtime-trust
fixtures still use the reviewed legacy policy paths.

- [ ] **Step 3: Verify packaged and installed independence**

Build the gem, install it into a temporary gem home, run both gem executables, install the source pack into a separate temporary target, rename the source checkout, and run both installed source-pack commands.

Expected: gem and source-pack commands work independently from their installed bytes.

- [ ] **Step 4: Commit legacy removal**

Turn the classified Step 1 result into a reviewed list of literal changed and
deleted file paths. Stage each changed path with `git add -- <exact-file>` and
each deletion with `git rm -- <exact-file>`; do not pass a directory, glob, or
`-A`. Require `git diff --cached --name-only` to equal that reviewed list, then
commit with message `refactor: remove legacy doctor implementation tree`.

### Task 7: Integrate validation, CI matrix, and documentation

**Files:**

- Modify: `bin/validate`
- Modify: `.github/workflows/validate.yml`
- Modify: `.github/workflows/lint.yml`
- Modify: `README.md`
- Modify: `CONTRIBUTING.md`
- Modify: `AGENTS.md`
- Modify: `docs/installation-and-upgrades.md`
- Modify: `CHANGELOG.md`
- Create: `docs/adr/0004-agent-workflows-ruby-package-boundary.md`

**Interfaces:**

- Consumes: all foundation tasks.
- Produces: canonical local and hosted validation contract and durable architecture record.

- [ ] **Step 1: Add package gates to `bin/validate`**

Run `ruby -Ilib` gem tests, package tests, `gem build`, and an isolated local install smoke before the existing installer suites. The build output goes under ignored `pkg/`; validation removes only the exact artifact it created.

- [ ] **Step 2: Add Linux Ruby matrix and macOS packaging smoke jobs**

On Linux, use a matrix with explicit `3.2` and the repository's pinned `3.4.6`
target. Both run `bin/validate`; lint may remain on `3.4.6` because syntax and
package compatibility are proven by validate on both versions.

Add a required `macos-packaging-smoke` job on the current supported macOS runner
and Ruby 3.4.6. It builds and installs the gem into an isolated gem home, runs both
executables outside the checkout, runs the shared process-runner timeout and
descendant-cleanup tests, and exercises copy plus live-symlink source-pack
installations in both flat and plugin-companion layouts. Upload a concise
non-secret receipt containing runner image, Ruby version, commit, commands, and
statuses. A skipped, stale-head, or missing macOS smoke is not a completed
foundation gate.

- [ ] **Step 3: Document the package boundary**

The ADR records the approved decisions from the design: Ruby/TypeScript ownership, dashed public packages, underscored requires, same-repository gem, stable CLI/private class boundary, stdlib-only runtime dependencies, no hidden runtime downloader, and deferred standalone executable evaluation.

Update `AGENTS.md` so its helper-location rule distinguishes package code from
skill helpers: shared production Ruby used by repo-wide commands or multiple
skills belongs in `lib/agent_workflows`; invoking skill folders retain thin
launchers and genuinely skill-local helpers. This policy change lands before
the domain-extraction plan moves any skill implementation.

README and installation docs distinguish:

```text
gem install agent-workflows       # RubyGems CLI distribution
bin/install-agent-workflows ...   # source-pack/plugin companion distribution
```

Neither path is described as replacing the other in the prerelease phase.

- [ ] **Step 4: Run complete validation**

Run:

```bash
bin/validate
git diff --check
```

Expected: `PASS agent-workflows validation`, no RuboCop offenses, and no whitespace errors.

- [ ] **Step 5: Run closeout review**

Use the repository `autoreview` skill on the complete branch diff. Verify every finding against the code, resolve accepted findings, rerun focused tests for touched files, then rerun `bin/validate` after any change.

- [ ] **Step 6: Commit foundation documentation and CI**

```bash
git add -- .github/workflows/validate.yml .github/workflows/lint.yml \
  AGENTS.md bin/validate README.md CONTRIBUTING.md \
  docs/installation-and-upgrades.md \
  docs/adr/0004-agent-workflows-ruby-package-boundary.md CHANGELOG.md
git commit -m "docs: define agent workflows gem distribution"
```

## Plan Completion Gate

The foundation is complete only when:

- the built gem and source-pack install both run the doctor from canonical library code;
- copy, symlink, flat, plugin-companion, and stack-sync layouts pass;
- the exact-head macOS packaging-smoke job passes and records its receipt;
- only the three explicitly deferred autonomous-merge policy files remain under
  `bin/agent_doctor`, with their removal owned by the merge-domain task;
- Ruby 3.2 and 3.4 validation pass;
- no package was published;
- current-head independent review and full `bin/validate` pass.
