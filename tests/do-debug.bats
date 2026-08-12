#!/usr/bin/env bats
#
# Fast/hermetic tests for the F9 debug helpers: `digital-ocean ssh|logs|status [cpu|gpu]`.
# The one external boundary — ssh to the droplets — is PATH-shimmed so the flow runs
# offline. The shim records `HOST | REMOTE-CMD` per call to $LOG/ssh so tests can assert
# the right droplet IP and the right remote command were used.
#
# The un-mocked counterpart is a live VERIFY run against a real `start`ed host
# (ssh gpu nvidia-smi / logs / status) — the boundary a stub can't prove.
#
# NOTE: bats silently ignores a mid-test bare `[[ ]]`; substring checks use `grep -q`.

DO=./bin/digital-ocean

setup() {
	CONFIG_DIR="$BATS_TEST_TMPDIR/do"
	SHIM="$BATS_TEST_TMPDIR/bin"
	LOG="$BATS_TEST_TMPDIR/log"
	mkdir -p "$CONFIG_DIR" "$SHIM" "$LOG"

	export DO_CONFIG_DIR="$CONFIG_DIR"
	export DO_SHIM_LOG="$LOG"

	_write_state
	_shim_ssh
	export PATH="$SHIM:/usr/bin:/bin"
}

# A .do/state as F6/F7 would have written it (only the fields F9 reads). #27:
# start now records the deployed app's port + health path here so status/logs
# stay manifest-free.
_write_state() {
	cat >"$CONFIG_DIR/state" <<EOF
DO_CPU_PUBLIC_IP='203.0.113.10'
DO_CPU_PRIVATE_IP='10.0.0.10'
DO_GPU_PUBLIC_IP='203.0.113.20'
DO_GPU_PRIVATE_IP='10.0.0.20'
APP_PORT='5000'
APP_HEALTH_PATH='/health'
EOF
}

# ssh: args look like `ssh <opts...> root@HOST [remote command...]`.
# Records "HOST | REMOTE-CMD" and can be told to fail is-active for a unit.
_shim_ssh() {
	cat >"$SHIM/ssh" <<'EOF'
#!/usr/bin/env bash
LOG="${DO_SHIM_LOG:?}"
host=""; cmd=()
while [ $# -gt 0 ]; do
	case "$1" in
	-o|-i) shift 2;;
	-*) shift;;
	*) host="$1"; shift; cmd=("$@"); break;;
	esac
done
printf '%s | %s\n' "$host" "${cmd[*]}" >>"$LOG/ssh"
# is-active probe: echo the canned state (default "active").
if printf '%s' "${cmd[*]}" | grep -q 'is-active'; then
	cat "$LOG/is_active" 2>/dev/null || echo active
fi
exit 0
EOF
	chmod +x "$SHIM/ssh"
}

# --- ssh --------------------------------------------------------------------

@test "ssh cpu opens interactive shell on the CPU public IP" {
	run "$DO" ssh cpu
	[ "$status" -eq 0 ]
	grep -q '203.0.113.10 | $' "$LOG/ssh"   # host, empty remote command
}

@test "ssh with no target defaults to cpu" {
	run "$DO" ssh
	[ "$status" -eq 0 ]
	grep -q 'root@203.0.113.10' "$LOG/ssh"
}

@test "ssh gpu targets the GPU public IP" {
	run "$DO" ssh gpu
	[ "$status" -eq 0 ]
	grep -q 'root@203.0.113.20' "$LOG/ssh"
}

@test "ssh gpu <cmd> passes the remote command through" {
	run "$DO" ssh gpu nvidia-smi
	[ "$status" -eq 0 ]
	grep -q '203.0.113.20 | nvidia-smi' "$LOG/ssh"
}

@test "ssh with an unknown target errors with usage and exit 2" {
	run "$DO" ssh bogus
	[ "$status" -eq 2 ]
	printf '%s' "$output" | grep -qi 'usage'
	[ ! -f "$LOG/ssh" ]   # never dialed out
}

# --- logs -------------------------------------------------------------------

@test "logs cpu tails app.service" {
	run "$DO" logs cpu
	[ "$status" -eq 0 ]
	grep -q '203.0.113.10 | .*journalctl -u app.service' "$LOG/ssh"
	grep -q 'journalctl -u app.service' "$LOG/ssh"
	grep -q -- '-n 100' "$LOG/ssh"
}

@test "logs gpu tails ollama.service" {
	run "$DO" logs gpu
	[ "$status" -eq 0 ]
	grep -q '203.0.113.20 | .*journalctl -u ollama.service' "$LOG/ssh"
}

@test "logs defaults to cpu" {
	run "$DO" logs
	[ "$status" -eq 0 ]
	grep -q '203.0.113.10 | .*journalctl -u app.service' "$LOG/ssh"
}

@test "logs -f streams (follow, no -n cap)" {
	run "$DO" logs cpu -f
	[ "$status" -eq 0 ]
	grep -q 'journalctl -u app.service -f' "$LOG/ssh"
}

# --- status -----------------------------------------------------------------

@test "status with no target reports BOTH nodes" {
	run "$DO" status
	[ "$status" -eq 0 ]
	grep -q 'root@203.0.113.10' "$LOG/ssh"
	grep -q 'root@203.0.113.20' "$LOG/ssh"
}

@test "status gpu reports only the GPU node" {
	run "$DO" status gpu
	[ "$status" -eq 0 ]
	grep -q 'root@203.0.113.20' "$LOG/ssh"
	! grep -q 'root@203.0.113.10' "$LOG/ssh"
}

@test "status runs is-active for the unit and probes health" {
	run "$DO" status cpu
	[ "$status" -eq 0 ]
	grep -q 'is-active.*app.service' "$LOG/ssh"
	grep -q '5000/health' "$LOG/ssh"
}

@test "status probes the app port + health path recorded in state, not a hardcoded 5000" {
	# #27: prove the cpu health probe is state-driven — a non-default port/path
	# from .do/state must be what gets probed.
	printf "DO_CPU_PUBLIC_IP='203.0.113.10'\nAPP_PORT='8080'\nAPP_HEALTH_PATH='/healthz'\n" \
		>"$CONFIG_DIR/state"
	run "$DO" status cpu
	[ "$status" -eq 0 ]
	grep -q '8080/healthz' "$LOG/ssh"
	[ "$(grep -c '5000/health' "$LOG/ssh")" -eq 0 ]
}

@test "status gpu probes the ollama /api/tags endpoint" {
	run "$DO" status gpu
	[ "$status" -eq 0 ]
	grep -q '11434/api/tags' "$LOG/ssh"
}

# --- error handling ---------------------------------------------------------

@test "no state file: ssh tells the user to run start first, non-zero" {
	rm -f "$CONFIG_DIR/state"
	run "$DO" ssh cpu
	[ "$status" -ne 0 ]
	printf '%s' "$output" | grep -qi 'start'
	[ ! -f "$LOG/ssh" ]
}

@test "no state file: status is non-zero with a helpful message" {
	rm -f "$CONFIG_DIR/state"
	run "$DO" status
	[ "$status" -ne 0 ]
	printf '%s' "$output" | grep -qi 'start'
}

@test "empty public IP in state is an error, not a dial-out to root@" {
	printf "DO_CPU_PUBLIC_IP=''\nDO_GPU_PUBLIC_IP=''\n" >"$CONFIG_DIR/state"
	run "$DO" ssh cpu
	[ "$status" -ne 0 ]
	[ ! -f "$LOG/ssh" ]
}
