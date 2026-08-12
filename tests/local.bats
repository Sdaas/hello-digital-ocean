#!/usr/bin/env bats
#
# Fast/hermetic tests for `digital-ocean local` (F3). External boundaries — the
# Ollama probe (curl), python3/venv, the browser (`open`) — are PATH-shimmed or
# simply not reached, so nothing real runs here. The un-mocked end-to-end (real
# venv + Flask + live Ollama + /health) lives in tests/integration/local.bats.
#
# NOTE on assertions: bats silently ignores a mid-test `[[ ]]` that returns
# false (it's a keyword, not a simple command, so it doesn't trip bats' failure
# trap). Substring checks therefore use `grep -q`, a simple command bats DOES
# catch mid-test. Only `[ ]` and simple commands are reliable before the last line.

DO=./bin/digital-ocean

setup() {
	STATE_DIR="$BATS_TEST_TMPDIR/state"
	SHIM="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$STATE_DIR" "$SHIM"
	# Redirect the CLI's pid/log state to a throwaway dir so tests never touch
	# the real demo/.localdata.
	export DO_LOCAL_STATE_DIR="$STATE_DIR"
}

# Put a stub `curl` on PATH that always fails — i.e. Ollama unreachable.
_shim_curl_unreachable() {
	cat >"$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
	chmod +x "$SHIM/curl"
	export PATH="$SHIM:$PATH"
}

@test "usage mentions the local subcommand" {
	run $DO --help
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "local"
}

@test "local down with nothing running is a friendly no-op (exit 0)" {
	run $DO local down
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "not running"
}

@test "local fails fast when Ollama is unreachable and starts no app" {
	_shim_curl_unreachable
	run $DO --app-dir demo local
	[ "$status" -ne 0 ]
	echo "$output" | grep -q "ollama serve"
	[ ! -f "$STATE_DIR/local.pid" ]
}

@test "unknown subcommand is rejected" {
	run $DO bogus
	[ "$status" -ne 0 ]
}

@test "local down runs under zsh" {
	if ! command -v zsh >/dev/null 2>&1; then skip "zsh not installed"; fi
	run zsh ./bin/digital-ocean local down
	[ "$status" -eq 0 ]
}
