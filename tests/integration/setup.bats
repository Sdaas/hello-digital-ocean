#!/usr/bin/env bats
#
# Opt-in, UN-MOCKED preflight for `digital-ocean setup` (F4). Runs the REAL DO
# auth boundary: a live `doctl account get` against DigitalOcean's API (a
# read-only call — provisions nothing, incurs no cost). This is the required
# real-boundary counterpart to the doctl stub in the fast lane (tests/setup.bats).
#
# Self-skips when doctl is absent or not authenticated, so `./test.sh
# --integration` stays green without DO credentials. Home is LOCAL / nightly;
# PR CI runs the fast lane only. It never writes to the real repo .do/ — config
# and creds are redirected to a throwaway dir.

DO=./bin/digital-ocean

setup() {
	command -v doctl >/dev/null 2>&1 || skip "doctl not installed"
	doctl account get >/dev/null 2>&1 || skip "doctl not authenticated (run: doctl auth init)"
	export DO_CONFIG_DIR="$BATS_TEST_TMPDIR/do"
}

@test "setup: real doctl auth passes preflight and writes a config" {
	# Requires a real DO-registered SSH key and a local key; if either is
	# missing, preflight legitimately fails — skip rather than assert.
	doctl compute ssh-key list --format Name --no-header 2>/dev/null | grep -q . ||
		skip "no DO-registered SSH key on this account"
	{ [ -f "$HOME/.ssh/id_ed25519" ] || [ -f "$HOME/.ssh/id_rsa" ]; } ||
		skip "no local SSH key (~/.ssh/id_ed25519 or id_rsa)"

	run $DO setup --non-interactive
	[ "$status" -eq 0 ]
	[ -f "$DO_CONFIG_DIR/config" ]
	grep -q "^DO_SSH_KEY_NAME=" "$DO_CONFIG_DIR/config"
}
