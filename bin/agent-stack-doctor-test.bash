#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for test_file in "$ROOT"/test/agent_doctor/*_test.rb; do
  ruby "$test_file"
done

help_output="$("$ROOT/bin/agent-stack" doctor --help)"
[[ "$help_output" == *"Usage: agent-stack doctor"* ]]

set +e
missing_ruby_output="$(RUBY_BIN=definitely-missing-ruby "$ROOT/bin/agent-stack" doctor --json 2>&1)"
missing_ruby_status=$?
set -e
[[ "$missing_ruby_status" -eq 64 && "$missing_ruby_output" == *"requires Ruby"* ]]

echo "PASS agent-stack doctor tests"
