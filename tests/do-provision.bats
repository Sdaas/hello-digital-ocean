#!/usr/bin/env bats
#
# Fast/hermetic tests for `digital-ocean provision` / `deprovision` (F6). The one
# external boundary — the `doctl` CLI (VPC, volume, droplet, ssh-key, attach) —
# is replaced by a STATEFUL PATH-shimmed stub that keeps a tiny on-disk registry,
# so `create` then `list` reflect each other across separate CLI processes. That
# lets us prove idempotent adopt-by-name without touching (or billing) real DO.
# The un-mocked counterpart (real VPC + one small volume against live DO) lives
# in tests/integration/do-provision.bats; the attach-positive path and real
# droplet create are deferred to F7 (billable/GPU).
#
# NOTE: bats silently ignores a mid-test `[[ ]]` that returns false, so
# substring checks use `grep -q` (a simple command bats DOES catch).

DO=./bin/digital-ocean

setup() {
	CONFIG_DIR="$BATS_TEST_TMPDIR/do"
	SHIM="$BATS_TEST_TMPDIR/bin"
	REG="$BATS_TEST_TMPDIR/reg"
	mkdir -p "$CONFIG_DIR" "$SHIM" "$REG"

	# Config + state land in a throwaway dir, never the real repo .do/.
	export DO_CONFIG_DIR="$CONFIG_DIR"
	# Registry dir the doctl stub reads/writes (its "cloud").
	export DOCTL_REG="$REG"

	_write_config
	_shim_doctl
	export PATH="$SHIM:/usr/bin:/bin"
}

# A valid .do/config as F4's `setup` would write it. DO_SSH_KEY_NAME matches the
# key the doctl stub reports, so key resolution succeeds by default.
_write_config() {
	cat >"$CONFIG_DIR/config" <<EOF
DO_REGION='ams3'
DO_CPU_SIZE='s-2vcpu-4gb'
DO_GPU_SIZE='gpu-4000adax1-20gb'
OLLAMA_MODEL='llama3.2:1b'
DO_SSH_KEY_NAME='my-mac'
APP_CREDENTIALS_FILE='$CONFIG_DIR/credentials'
EOF
}

# Stateful doctl stub. Registry file $DOCTL_REG/resources holds one line per
# resource: "TYPE NAME ID PUB PRIV" (PUB/PRIV are '-' for non-droplets).
# $DOCTL_REG/attach holds "VOLID DROPID" lines. $DOCTL_REG/calls logs every
# invocation so tests can assert what did / didn't run.
_shim_doctl() {
	cat >"$SHIM/doctl" <<'EOF'
#!/usr/bin/env bash
REG="${DOCTL_REG:?}"; RES="$REG/resources"; ATT="$REG/attach"; CALLS="$REG/calls"
: >>"$RES"; : >>"$ATT"; : >>"$CALLS"
printf '%s\n' "$*" >>"$CALLS"

# Real doctl's `vpcs create` does NOT support --format (unlike volume/droplet
# create) — mimic that failure so ensure_vpc can't regress to passing it (#18 VERIFY).
case "$*" in "vpcs create"*--format*) echo "Error: unknown flag: --format" >&2; exit 1;; esac

# Split flags from positionals; capture the flag values we care about.
name=""; args=()
while [ $# -gt 0 ]; do
	case "$1" in
	--name) name="$2"; shift 2;;
	--region|--size|--image|--ssh-keys|--vpc-uuid|--format|--fs-type) shift 2;;
	--no-header|--wait|--force) shift;;
	*) args+=("$1"); shift;;
	esac
done

# Deterministic id/IPs from a name, so assertions are stable.
_id() { printf 'id-%s' "$1"; }
_ips() { # name -> "PUB PRIV"
	case "$1" in
	*-cpu) echo "203.0.113.10 10.10.0.10";;
	*-gpu) echo "203.0.113.20 10.10.0.20";;
	*) echo "203.0.113.99 10.10.0.99";;
	esac
}
_find_id() { awk -v t="$1" -v n="$2" '$1==t && $2==n{print $3; exit}' "$RES"; }
_add() { printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" >>"$RES"; }
_del_by_id() { grep -v " $1 " "$RES" >"$RES.tmp" 2>/dev/null; mv "$RES.tmp" "$RES"; }

key="${args[0]:-} ${args[1]:-}"
case "$key" in
"vpcs list")
	awk '$1=="vpc"{print $2, $3}' "$RES";;
"vpcs create")
	id="$(_id "$name")"; [ -n "$(_find_id vpc "$name")" ] || _add vpc "$name" "$id" - -; printf '%s\n' "$id";;
"vpcs delete")
	_del_by_id "${args[2]}";;
"compute volume")
	case "${args[2]:-}" in
	list) awk '$1=="volume"{print $2, $3}' "$RES";;
	create) vn="${args[3]}"; id="$(_id "$vn")"; [ -n "$(_find_id volume "$vn")" ] || _add volume "$vn" "$id" - -; printf '%s\n' "$id";;
	delete) _del_by_id "${args[3]}";;
	get) # volume get <id> --format DropletIDs : print the droplet it's attached to
		awk -v v="${args[3]}" '$1==v{print $2}' "$ATT";;
	esac;;
"compute volume-action")
	# volume-action attach <volid> <dropid>
	printf '%s %s\n' "${args[3]}" "${args[4]}" >>"$ATT";;
"compute droplet")
	case "${args[2]:-}" in
	list) awk '$1=="droplet"{print $2, $3, $4, $5}' "$RES";;
	create) dn="${args[3]}"; id="$(_id "$dn")"; read -r pub priv <<<"$(_ips "$dn")"
		[ -n "$(_find_id droplet "$dn")" ] || _add droplet "$dn" "$id" "$pub" "$priv"
		printf '%s %s %s\n' "$id" "$pub" "$priv";;
	delete) _del_by_id "${args[3]}";;
	esac;;
"compute ssh-key")
	# ssh-key list --format Name,ID : report a single key named my-mac.
	# Real doctl PADS the Name column with trailing spaces to align it — emulate
	# that (regression for _resolve_ssh_key stripping the pad; found at #18 VERIFY).
	printf '%-28s %s\n' "${DOCTL_KEY_NAME:-my-mac}" "111";;
"account get") exit 0;;
esac
exit 0
EOF
	chmod +x "$SHIM/doctl"
}

_count() { grep -c "^$1 " "$REG/resources" 2>/dev/null || true; }

# --- provision --------------------------------------------------------------

@test "provision writes .do/state with VPC, volumes, droplets and IPs (exit 0)" {
	run $DO provision
	[ "$status" -eq 0 ]
	[ -f "$CONFIG_DIR/state" ]
	grep -q "DO_VPC_ID='id-hello-do-vpc'" "$CONFIG_DIR/state"
	grep -q "DO_DATA_VOLUME_ID='id-hello-do-data'" "$CONFIG_DIR/state"
	grep -q "DO_MODELS_VOLUME_ID='id-hello-do-models'" "$CONFIG_DIR/state"
	grep -q "DO_CPU_DROPLET_ID='id-hello-do-cpu'" "$CONFIG_DIR/state"
	grep -q "DO_GPU_DROPLET_ID='id-hello-do-gpu'" "$CONFIG_DIR/state"
	grep -q "DO_CPU_PUBLIC_IP='203.0.113.10'" "$CONFIG_DIR/state"
	grep -q "DO_GPU_PRIVATE_IP='10.10.0.20'" "$CONFIG_DIR/state"
}

@test "provision writes state file with private (0600) perms" {
	run $DO provision
	[ "$status" -eq 0 ]
	# GNU stat (-c, Linux/CI) first; fall back to BSD stat (-f, macOS). The old
	# order broke on Linux: GNU `stat -f` doesn't error, so the fallback never ran.
	perms="$(stat -c '%a' "$CONFIG_DIR/state" 2>/dev/null || stat -f '%Lp' "$CONFIG_DIR/state")"
	[ "$perms" = "600" ]
}

@test "provision attaches data->cpu and models->gpu" {
	run $DO provision
	[ "$status" -eq 0 ]
	grep -q "id-hello-do-data id-hello-do-cpu" "$REG/attach"
	grep -q "id-hello-do-models id-hello-do-gpu" "$REG/attach"
}

@test "provision creates exactly one of each resource" {
	run $DO provision
	[ "$status" -eq 0 ]
	[ "$(_count vpc)" -eq 1 ]
	[ "$(_count volume)" -eq 2 ]
	[ "$(_count droplet)" -eq 2 ]
}

@test "re-running provision adopts by name — no duplicates, no new create" {
	run $DO provision
	[ "$status" -eq 0 ]
	: >"$REG/calls"   # forget the first run's calls
	run $DO provision
	[ "$status" -eq 0 ]
	# Registry still holds exactly one of each — nothing duplicated.
	[ "$(_count vpc)" -eq 1 ]
	[ "$(_count volume)" -eq 2 ]
	[ "$(_count droplet)" -eq 2 ]
	# And the second run issued no create calls at all.
	run grep -E "(vpcs create|volume create|droplet create)" "$REG/calls"
	[ "$status" -ne 0 ]
}

@test "provision without a config fails and provisions nothing" {
	rm -f "$CONFIG_DIR/config"
	run $DO provision
	[ "$status" -ne 0 ]
	[ ! -f "$CONFIG_DIR/state" ]
	echo "$output" | grep -q "setup"
	run grep -E "create" "$REG/calls"
	[ "$status" -ne 0 ]
}

@test "provision fails fast (nothing created) when the SSH key name is unknown" {
	# Config asks for a key the account doesn't have.
	sed -i.bak "s/DO_SSH_KEY_NAME='my-mac'/DO_SSH_KEY_NAME='ghost'/" "$CONFIG_DIR/config"
	run $DO provision
	[ "$status" -ne 0 ]
	echo "$output" | grep -qi "ssh key"
	# Key is resolved up front, so no billable resource was created.
	run grep -E "create" "$REG/calls"
	[ "$status" -ne 0 ]
}

@test "provision fails cleanly (no set -u crash) when config lacks DO_SSH_KEY_NAME" {
	# A config with no key line must produce the 'key not found' error, not an
	# 'unbound variable' crash.
	grep -v "DO_SSH_KEY_NAME" "$CONFIG_DIR/config" >"$CONFIG_DIR/config.new"
	mv "$CONFIG_DIR/config.new" "$CONFIG_DIR/config"
	run $DO provision
	[ "$status" -ne 0 ]
	echo "$output" | grep -qi "ssh key"
	! echo "$output" | grep -q "unbound variable"
}

@test "provision errors if a volume is already attached to a different droplet" {
	# Pre-seed the data volume as existing and attached to a foreign droplet.
	printf 'volume hello-do-data id-hello-do-data - -\n' >>"$REG/resources"
	printf 'id-hello-do-data 999\n' >>"$REG/attach"
	run $DO provision
	[ "$status" -ne 0 ]
	echo "$output" | grep -qi "attached"
}

# --- deprovision ------------------------------------------------------------

@test "deprovision destroys droplets, keeps volumes, prunes droplet state" {
	run $DO provision
	[ "$status" -eq 0 ]
	run $DO deprovision
	[ "$status" -eq 0 ]
	# Droplets gone, volumes + VPC remain.
	[ "$(_count droplet)" -eq 0 ]
	[ "$(_count volume)" -eq 2 ]
	[ "$(_count vpc)" -eq 1 ]
	# Droplet fields pruned from state; volume/vpc fields still present.
	grep -q "DO_CPU_DROPLET_ID=''" "$CONFIG_DIR/state"
	grep -q "DO_DATA_VOLUME_ID='id-hello-do-data'" "$CONFIG_DIR/state"
}

@test "deprovision --volumes destroys droplets, volumes and VPC" {
	run $DO provision
	[ "$status" -eq 0 ]
	run $DO deprovision --volumes
	[ "$status" -eq 0 ]
	[ "$(_count droplet)" -eq 0 ]
	[ "$(_count volume)" -eq 0 ]
	[ "$(_count vpc)" -eq 0 ]
}

@test "deprovision with no state is a no-op (exit 0)" {
	run $DO deprovision
	[ "$status" -eq 0 ]
}

# --- misc -------------------------------------------------------------------

@test "provision/deprovision are hidden from usage" {
	run $DO --help
	[ "$status" -eq 0 ]
	# Hidden low-level commands: F7 start / F8 destroy are the public surface.
	# They must not appear as a listed command (an indented "Commands:" entry) —
	# the description prose "provisions/tears down" is fine, so match a command row.
	echo "$output" | grep -qE '^[[:space:]]+de?provision\b' && return 1
	true
}

@test "provision runs under zsh" {
	if ! command -v zsh >/dev/null 2>&1; then skip "zsh not installed"; fi
	run zsh ./bin/digital-ocean provision
	[ "$status" -eq 0 ]
}
