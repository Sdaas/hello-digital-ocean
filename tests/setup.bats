#!/usr/bin/env bats
#
# Fast/hermetic tests for `digital-ocean setup` (F4). Every external boundary —
# the doctl CLI (auth + ssh-key list), the ssh/scp/curl tools, the local SSH
# key file, and the config/creds filesystem — is PATH-shimmed or redirected to a
# throwaway dir, so nothing real (and nothing billable) runs here. The un-mocked
# counterpart (real `doctl account get`) lives in tests/integration/setup.bats.
#
# NOTE on assertions: bats silently ignores a mid-test `[[ ]]` that returns
# false, so substring checks use `grep -q` (a simple command bats DOES catch).

DO=./bin/digital-ocean

setup() {
	CONFIG_DIR="$BATS_TEST_TMPDIR/do"
	SHIM="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$CONFIG_DIR" "$SHIM"
	# Config + creds land in a throwaway dir, never the real repo .do/.
	export DO_CONFIG_DIR="$CONFIG_DIR"
	# An authoritative local SSH key that exists (setup uses this path exactly
	# when set, with no ~/.ssh fallback — keeps the negative test deterministic).
	export DO_SSH_KEY_FILE="$BATS_TEST_TMPDIR/id_ed25519"
	: >"$DO_SSH_KEY_FILE"
	# Happy-path shims for the tools preflight needs. A minimal PATH (shim +
	# coreutils) hides any real doctl installed on this machine.
	_shim_present ssh
	_shim_present scp
	_shim_present curl
	_shim_doctl
	export PATH="$SHIM:/usr/bin:/bin"
}

# A tool that just needs to be found by `command -v` (never executed).
_shim_present() {
	printf '#!/usr/bin/env bash\nexit 0\n' >"$SHIM/$1"
	chmod +x "$SHIM/$1"
}

# A configurable doctl stub. DOCTL_ACCOUNT_RC controls `account get` (default 0
# = authed); DOCTL_KEYS controls `compute ssh-key list` output (default one key;
# set empty for "no DO-registered key").
_shim_doctl() {
	cat >"$SHIM/doctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = account ] && [ "$2" = get ]; then
	exit "${DOCTL_ACCOUNT_RC:-0}"
fi
if [ "$1" = compute ] && [ "$2" = ssh-key ] && [ "$3" = list ]; then
	keys="${DOCTL_KEYS-my-mac}"
	[ -n "$keys" ] && printf '%s\n' "$keys"
	exit 0
fi
exit 0
EOF
	chmod +x "$SHIM/doctl"
}

@test "usage mentions the setup subcommand" {
	run $DO --help
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "setup"
}

@test "setup --non-interactive writes .do/config with defaults and exits 0" {
	run $DO setup --non-interactive
	[ "$status" -eq 0 ]
	[ -f "$CONFIG_DIR/config" ]
	grep -q "DO_REGION='ams3'" "$CONFIG_DIR/config"
	grep -q "DO_CPU_SIZE='s-2vcpu-4gb'" "$CONFIG_DIR/config"
	grep -q "DO_GPU_SIZE='gpu-4000adax1-20gb'" "$CONFIG_DIR/config"
	grep -q "OLLAMA_MODEL='llama3.2:1b'" "$CONFIG_DIR/config"
	# #18/#19: selectable backend (default cpu), CPU Ollama node size, optional firewall.
	grep -q "OLLAMA_BACKEND='cpu'" "$CONFIG_DIR/config"
	grep -q "DO_OLLAMA_CPU_SIZE='s-8vcpu-16gb-amd'" "$CONFIG_DIR/config"
	grep -q "DO_ENABLE_FIREWALL='0'" "$CONFIG_DIR/config"
}

@test "setup records an OLLAMA_BACKEND env override (gpu)" {
	OLLAMA_BACKEND=gpu run $DO setup --non-interactive
	[ "$status" -eq 0 ]
	grep -q "OLLAMA_BACKEND='gpu'" "$CONFIG_DIR/config"
}

@test "setup captures the DO-registered key name from doctl" {
	run $DO setup --non-interactive
	[ "$status" -eq 0 ]
	grep -q "DO_SSH_KEY_NAME='my-mac'" "$CONFIG_DIR/config"
}

@test "an env override wins over the default" {
	DO_REGION=nyc1 run $DO setup --non-interactive
	[ "$status" -eq 0 ]
	grep -q "DO_REGION='nyc1'" "$CONFIG_DIR/config"
}

@test "setup ensures the credentials file exists" {
	run $DO setup --non-interactive
	[ "$status" -eq 0 ]
	[ -f "$CONFIG_DIR/credentials" ]
}

@test "preflight fails (no config) when doctl is missing" {
	rm -f "$SHIM/doctl"
	run $DO setup --non-interactive
	[ "$status" -ne 0 ]
	[ ! -f "$CONFIG_DIR/config" ]
	echo "$output" | grep -q "doctl"
}

@test "preflight fails (no config) when DO auth is bad" {
	DOCTL_ACCOUNT_RC=1 run $DO setup --non-interactive
	[ "$status" -ne 0 ]
	[ ! -f "$CONFIG_DIR/config" ]
	echo "$output" | grep -q "doctl auth init"
}

@test "preflight fails (no config) when no local SSH key exists" {
	export DO_SSH_KEY_FILE="$BATS_TEST_TMPDIR/does-not-exist"
	run $DO setup --non-interactive
	[ "$status" -ne 0 ]
	[ ! -f "$CONFIG_DIR/config" ]
	echo "$output" | grep -q "ssh-keygen"
}

@test "preflight fails (no config) when no DO-registered key exists" {
	DOCTL_KEYS="" run $DO setup --non-interactive
	[ "$status" -ne 0 ]
	[ ! -f "$CONFIG_DIR/config" ]
	echo "$output" | grep -q "ssh-key import"
}

@test "re-run is idempotent — a single DO_REGION line, still valid" {
	run $DO setup --non-interactive
	[ "$status" -eq 0 ]
	run $DO setup --non-interactive
	[ "$status" -eq 0 ]
	[ "$(grep -c '^DO_REGION=' "$CONFIG_DIR/config")" -eq 1 ]
}

@test "a prior config value becomes the default on re-run" {
	DO_REGION=sfo3 run $DO setup --non-interactive
	[ "$status" -eq 0 ]
	# Second run without the override should preserve the stored value.
	run $DO setup --non-interactive
	[ "$status" -eq 0 ]
	grep -q "DO_REGION='sfo3'" "$CONFIG_DIR/config"
}

@test "a value with a single quote round-trips (config stays sourceable)" {
	# A DO key name containing a quote must not corrupt the config or break the
	# next run's `. config`.
	DOCTL_KEYS="Bob's key" run $DO setup --non-interactive
	[ "$status" -eq 0 ]
	# Re-run: sourcing the prior config must not error, and the value survives.
	run $DO setup --non-interactive
	[ "$status" -eq 0 ]
	grep -q "DO_SSH_KEY_NAME='Bob'" "$CONFIG_DIR/config"
	# The stored value sources back exactly.
	( set -eu; . "$CONFIG_DIR/config"; [ "$DO_SSH_KEY_NAME" = "Bob's key" ] )
}

@test "setup runs under zsh" {
	if ! command -v zsh >/dev/null 2>&1; then skip "zsh not installed"; fi
	run zsh ./bin/digital-ocean setup --non-interactive
	[ "$status" -eq 0 ]
}
