test_fixture_clone_writer_timeout_preserves_primary_failure() {
  local temporary ruby_without_ready output status
  temporary="$(make_tmp_dir)"
  ruby_without_ready="$temporary/ruby-without-ready"
  cat > "$ruby_without_ready" <<BASH
#!/usr/bin/env bash
if [[ "\${1:-}" = "-rtimeout" ]]; then
  exit 1
fi
exec "$RUBY_BIN" "\$@"
BASH
  chmod +x "$ruby_without_ready"

  if output="$(
    (
      RUBY_BIN="$ruby_without_ready"
      # shellcheck disable=SC2154,SC2329 # Called by fixture_clone_writer_start in this subshell.
      sleep() { SECONDS="$deadline"; }
      fixture_clone_constructor_with_writer create_origin "$temporary"
    ) 2>&1
  )"; then
    status=0
  else
    status=$?
  fi

  [[ "$status" -ne 0 ]] || fail "temporary-pack writer timeout unexpectedly succeeded"
  assert_contains "$output" "temporary-pack writer did not start"
  [[ "$output" != *"temporary-pack writer failed"* ]] || fail "temporary-pack writer timeout reported cleanup failure"
}
