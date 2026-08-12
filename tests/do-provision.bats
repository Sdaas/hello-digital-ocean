#!/usr/bin/env bats
#
# Fast/hermetic tests for `digital-ocean provision` (F6) and `stop` / `destroy`
# (F8, the public teardown). The one
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
	APP="$BATS_TEST_TMPDIR/app"
	mkdir -p "$CONFIG_DIR" "$SHIM" "$REG" "$APP"

	# Config + state land in a throwaway dir, never the real repo .do/.
	export DO_CONFIG_DIR="$CONFIG_DIR"
	# Registry dir the doctl stub reads/writes (its "cloud").
	export DOCTL_REG="$REG"
	# Per-env infra (region/backend/sizes) now comes from the app manifest (#29).
	# Export DO_APP_DIR so every `$DO provision` here picks it up without --app-dir
	# on each call; --env defaults to prod → resources are named demo-prod-*.
	_write_manifest
	export DO_APP_DIR="$APP"

	_write_config
	_shim_doctl
	export PATH="$SHIM:/usr/bin:/bin"
}

# A minimal app manifest (name + a prod/staging deployments block, #29). name
# 'demo' + env 'prod' → the demo-prod-* resource names asserted below.
_write_manifest() {
	cat >"$APP/digital-ocean.yml" <<'EOF'
name: demo
app_dir: .
entrypoint: app.py
requirements: requirements.txt
port: 5000
health_path: /health
ollama_model: llama3.2:1b
credentials_env_file: true
deployments:
  prod:
    region: blr1
    ollama_backend: cpu
    app_size: s-2vcpu-4gb
    ollama_cpu_size: s-8vcpu-16gb-amd
    firewall: false
  staging:
    region: blr1
    ollama_backend: cpu
    app_size: s-2vcpu-4gb
    ollama_cpu_size: s-8vcpu-16gb-amd
    firewall: false
EOF
}

# A valid .do/config as F4's `setup` would write it — now just machine-local facts
# (#29): DO_SSH_KEY_NAME matches the key the doctl stub reports (resolution
# succeeds by default) + the local credentials-file path.
_write_config() {
	cat >"$CONFIG_DIR/config" <<EOF
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
: >>"$RES"; : >>"$ATT"; : >>"$CALLS"; : >>"$REG/assign"
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
	*-backend) echo "203.0.113.10 10.10.0.10";;
	*-ollama-*) echo "203.0.113.20 10.10.0.20";;
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
	# Bug 2 (F8): a VPC auto-promoted to the region default returns 403 on delete.
	# DOCTL_VPC_DEFAULT=1 makes the stub emit that so teardown's tolerance is tested.
	if [ "${DOCTL_VPC_DEFAULT:-0}" = "1" ]; then
		echo "Error: DELETE https://api.digitalocean.com/v2/vpcs/${args[2]}: 403 Can not delete default VPCs" >&2
		exit 1
	fi
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
	delete)
		# Bug 1 (F8): DO droplet delete is ASYNC. DOCTL_DROPLET_LINGER=N makes the
		# droplet survive N subsequent `droplet get` polls before reporting gone, so
		# the wait-until-gone loop is really exercised. Default 0 = gone immediately.
		did="${args[3]}"
		if [ "${DOCTL_DROPLET_LINGER:-0}" -gt 0 ]; then
			printf '%s %s\n' "$did" "${DOCTL_DROPLET_LINGER}" >>"$REG/pending"
		else
			_del_by_id "$did"
		fi;;
	get)
		# `droplet get <id>` — exit 0 (+print id) while it still exists, exit 1 once gone.
		gid="${args[3]}"
		if [ -f "$REG/pending" ] && grep -q "^$gid " "$REG/pending"; then
			cnt="$(awk -v i="$gid" '$1==i{print $2; exit}' "$REG/pending")"
			if [ "$cnt" -gt 1 ]; then
				awk -v i="$gid" '{ if ($1==i) print $1, $2-1; else print }' "$REG/pending" >"$REG/pending.tmp"
				mv "$REG/pending.tmp" "$REG/pending"
				printf '%s\n' "$gid"; exit 0
			fi
			grep -v "^$gid " "$REG/pending" >"$REG/pending.tmp" 2>/dev/null; mv "$REG/pending.tmp" "$REG/pending"
			_del_by_id "$gid"; exit 1
		fi
		if [ -n "$(awk -v i="$gid" '$1=="droplet" && $3==i{print; exit}' "$RES")" ]; then
			printf '%s\n' "$gid"; exit 0
		fi
		exit 1;;
	esac;;
"compute firewall")
	# F8 teardown deletes the two `start`-created firewalls. Best-effort delete-by-id.
	case "${args[2]:-}" in
	delete) _del_by_id "${args[3]}";;
	esac;;
"compute ssh-key")
	# ssh-key list --format Name,ID : report a single key named my-mac.
	# Real doctl PADS the Name column with trailing spaces to align it — emulate
	# that (regression for _resolve_ssh_key stripping the pad; found at #18 VERIFY).
	printf '%-28s %s\n' "${DOCTL_KEY_NAME:-my-mac}" "111";;
"projects list")
	# `projects list --format ID,Name --no-header` : ID then Name (adopt-by-name).
	awk '$1=="project"{print $3, $2}' "$RES";;
"projects create")
	# DOCTL_PROJECTS_DENY=1 simulates a token without projects scope (like #16's
	# missing firewall scope) so the best-effort path can be tested.
	if [ "${DOCTL_PROJECTS_DENY:-0}" = "1" ]; then
		echo "Error: forbidden (projects scope)" >&2; exit 1
	fi
	# create --name <n> --purpose ... --environment ... --format ID --no-header
	id="$(_id "$name")"; [ -n "$(_find_id project "$name")" ] || _add project "$name" "$id" - -
	printf '%s\n' "$id";;
"projects resources")
	# `projects resources assign <proj-id> --resource <urn> ...`. The arg loop above
	# already split argv, so the URNs live in args[] (interleaved with --resource).
	# Record "PROJID URN" pairs so tests can assert exactly what was assigned.
	if [ "${args[2]:-}" = assign ]; then
		pid="${args[3]:-}"
		for u in "${args[@]}"; do
			case "$u" in do:*) printf '%s %s\n' "$pid" "$u" >>"$REG/assign";; esac
		done
	fi;;
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
	[ -f "$CONFIG_DIR/state.prod" ]
	# #17: VPC name is region-scoped (VPCs are region-bound; backend-aware regions
	# must not collide on a shared name), so the blr1 config yields demo-prod-vpc-blr1.
	grep -q "DO_VPC_ID='id-demo-prod-vpc-blr1'" "$CONFIG_DIR/state.prod"
	grep -q "DO_DATA_VOLUME_ID='id-demo-prod-data'" "$CONFIG_DIR/state.prod"
	grep -q "DO_MODELS_VOLUME_ID='id-demo-prod-models'" "$CONFIG_DIR/state.prod"
	grep -q "DO_CPU_DROPLET_ID='id-demo-prod-backend'" "$CONFIG_DIR/state.prod"
	grep -q "DO_GPU_DROPLET_ID='id-demo-prod-ollama-cpu'" "$CONFIG_DIR/state.prod"
	grep -q "DO_CPU_PUBLIC_IP='203.0.113.10'" "$CONFIG_DIR/state.prod"
	grep -q "DO_GPU_PRIVATE_IP='10.10.0.20'" "$CONFIG_DIR/state.prod"
}

@test "#29: --env staging names resources demo-staging-* in a separate state file" {
	run $DO --env staging provision
	[ "$status" -eq 0 ]
	# Staging state is its own file, kept apart from prod's.
	[ -f "$CONFIG_DIR/state.staging" ]
	[ ! -f "$CONFIG_DIR/state.prod" ]
	grep -q "DO_VPC_ID='id-demo-staging-vpc-blr1'" "$CONFIG_DIR/state.staging"
	grep -q "DO_DATA_VOLUME_ID='id-demo-staging-data'" "$CONFIG_DIR/state.staging"
	grep -q "DO_CPU_DROPLET_ID='id-demo-staging-backend'" "$CONFIG_DIR/state.staging"
	grep -q "DO_GPU_DROPLET_ID='id-demo-staging-ollama-cpu'" "$CONFIG_DIR/state.staging"
}

@test "#29: prod and staging can coexist — each in its own state file" {
	run $DO --env prod provision
	[ "$status" -eq 0 ]
	run $DO --env staging provision
	[ "$status" -eq 0 ]
	[ -f "$CONFIG_DIR/state.prod" ]
	[ -f "$CONFIG_DIR/state.staging" ]
	# Two of each resource-kind now exist (one per env), proving no collision.
	[ "$(_count droplet)" -eq 4 ]
	[ "$(_count volume)" -eq 4 ]
}

@test "#29: the ollama node name tracks the ollama backend (gpu → -ollama-gpu)" {
	# ollama_backend comes from the manifest; an env override still wins (and logs).
	OLLAMA_BACKEND=gpu run $DO provision
	[ "$status" -eq 0 ]
	grep -q "DO_GPU_DROPLET_ID='id-demo-prod-ollama-gpu'" "$CONFIG_DIR/state.prod"
}

@test "#29: an env var overriding a manifest infra value is logged" {
	# DO_REGION (env) overrides the manifest's blr1 → the override is announced.
	DO_REGION=tor1 run $DO provision
	[ "$status" -eq 0 ]
	printf '%s' "$output" | grep -qi "DO_REGION overrides manifest"
	grep -q "DO_VPC_ID='id-demo-prod-vpc-tor1'" "$CONFIG_DIR/state.prod"
}

@test "#30: provision creates the <name>-<env> DO Project and records it in state" {
	run $DO provision
	[ "$status" -eq 0 ]
	# A project named demo-prod was created and its id recorded.
	grep -q "^project demo-prod " "$REG/resources"
	grep -q "DO_PROJECT_NAME='demo-prod'" "$CONFIG_DIR/state.prod"
	grep -q "DO_PROJECT_ID='id-demo-prod'" "$CONFIG_DIR/state.prod"
}

@test "#30: provision assigns both droplets and both volumes to the project" {
	run $DO provision
	[ "$status" -eq 0 ]
	# All four resource URNs assigned to the demo-prod project id.
	grep -q "id-demo-prod do:droplet:id-demo-prod-backend" "$REG/assign"
	grep -q "id-demo-prod do:droplet:id-demo-prod-ollama-cpu" "$REG/assign"
	grep -q "id-demo-prod do:volume:id-demo-prod-data" "$REG/assign"
	grep -q "id-demo-prod do:volume:id-demo-prod-models" "$REG/assign"
}

@test "#30: --env staging groups under a demo-staging project" {
	run $DO --env staging provision
	[ "$status" -eq 0 ]
	grep -q "^project demo-staging " "$REG/resources"
	grep -q "DO_PROJECT_NAME='demo-staging'" "$CONFIG_DIR/state.staging"
	grep -q "id-demo-staging do:droplet:id-demo-staging-backend" "$REG/assign"
}

@test "#30: re-running provision adopts the project — no second create" {
	run $DO provision
	[ "$status" -eq 0 ]
	: >"$REG/calls"
	run $DO provision
	[ "$status" -eq 0 ]
	# Still exactly one project, and the second run issued no `projects create`.
	[ "$(_count project)" -eq 1 ]
	run grep -E "projects create" "$REG/calls"
	[ "$status" -ne 0 ]
}

@test "#30: project grouping is best-effort — a scopeless token still deploys" {
	# Token lacks projects scope: create is denied. Provision must still succeed
	# (resources created), with a warning, and no project id in state.
	DOCTL_PROJECTS_DENY=1 run $DO provision
	[ "$status" -eq 0 ]
	[ "$(_count droplet)" -eq 2 ]
	[ "$(_count volume)" -eq 2 ]
	printf '%s' "$output" | grep -qi "project"
	grep -q "DO_PROJECT_ID=''" "$CONFIG_DIR/state.prod"
}

@test "provision requires --app-dir/manifest (fails without one)" {
	# Unset the DO_APP_DIR fallback so no app is selected.
	unset DO_APP_DIR
	run $DO provision
	[ "$status" -ne 0 ]
	printf '%s' "$output" | grep -qi 'app-dir'
}

@test "#17: the VPC name is region-scoped so regions never collide" {
	# A different region must yield a different VPC (VPCs are region-bound). This is
	# the cross-region adoption bug found at the #17 blr1 live VERIFY.
	{ grep -v "^DO_REGION=" "$CONFIG_DIR/config"; echo "DO_REGION='tor1'"; } \
		>"$CONFIG_DIR/config.new" && mv "$CONFIG_DIR/config.new" "$CONFIG_DIR/config"
	run $DO provision
	[ "$status" -eq 0 ]
	grep -q "DO_VPC_ID='id-demo-prod-vpc-tor1'" "$CONFIG_DIR/state.prod"
}

@test "provision writes state file with private (0600) perms" {
	run $DO provision
	[ "$status" -eq 0 ]
	# GNU stat (-c, Linux/CI) first; fall back to BSD stat (-f, macOS). The old
	# order broke on Linux: GNU `stat -f` doesn't error, so the fallback never ran.
	perms="$(stat -c '%a' "$CONFIG_DIR/state.prod" 2>/dev/null || stat -f '%Lp' "$CONFIG_DIR/state.prod")"
	[ "$perms" = "600" ]
}

@test "provision attaches data->cpu and models->gpu" {
	run $DO provision
	[ "$status" -eq 0 ]
	grep -q "id-demo-prod-data id-demo-prod-backend" "$REG/attach"
	grep -q "id-demo-prod-models id-demo-prod-ollama-cpu" "$REG/attach"
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
	[ ! -f "$CONFIG_DIR/state.prod" ]
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
	printf 'volume demo-prod-data id-demo-prod-data - -\n' >>"$REG/resources"
	printf 'id-demo-prod-data 999\n' >>"$REG/attach"
	run $DO provision
	[ "$status" -ne 0 ]
	echo "$output" | grep -qi "attached"
}

# --- stop / destroy (F8) ----------------------------------------------------
# `stop` = destroy droplets + firewalls, keep volumes + VPC. `destroy` = also
# volumes + VPC (confirm). Both wait for droplets to be really gone (Bug 1) and
# `destroy` tolerates a non-deletable default VPC (Bug 2). Poll waits are tiny.

# Fast poll so the wait-until-gone loop doesn't slow the suite.
_fast_teardown() { export DO_DELETE_POLL_SLEEP=1 DO_DELETE_WAIT_SECS=5; }

@test "stop destroys droplets, keeps volumes + VPC, prunes droplet state" {
	run $DO provision
	[ "$status" -eq 0 ]
	_fast_teardown
	run $DO stop
	[ "$status" -eq 0 ]
	# Droplets gone, volumes + VPC remain.
	[ "$(_count droplet)" -eq 0 ]
	[ "$(_count volume)" -eq 2 ]
	[ "$(_count vpc)" -eq 1 ]
	# Droplet fields pruned from state; volume/vpc fields still present.
	grep -q "DO_CPU_DROPLET_ID=''" "$CONFIG_DIR/state.prod"
	grep -q "DO_DATA_VOLUME_ID='id-demo-prod-data'" "$CONFIG_DIR/state.prod"
}

@test "stop deletes the two firewalls when their IDs are in state" {
	run $DO provision
	[ "$status" -eq 0 ]
	# `start` records firewall IDs; simulate that so teardown has them to delete.
	printf "DO_CPU_FW_ID='fw-cpu'\nDO_GPU_FW_ID='fw-gpu'\n" >>"$CONFIG_DIR/state.prod"
	_fast_teardown
	: >"$REG/calls"
	run $DO stop
	[ "$status" -eq 0 ]
	grep -q "compute firewall delete fw-cpu" "$REG/calls"
	grep -q "compute firewall delete fw-gpu" "$REG/calls"
}

@test "stop waits for droplets to be gone before returning (Bug 1)" {
	run $DO provision
	[ "$status" -eq 0 ]
	_fast_teardown
	export DOCTL_DROPLET_LINGER=2   # each droplet survives 2 polls, then reports gone
	: >"$REG/calls"
	run $DO stop
	[ "$status" -eq 0 ]
	# The loop actually polled: at least one `droplet get` was issued.
	grep -q "compute droplet get" "$REG/calls"
	# And the droplets really are gone once stop returns.
	[ "$(_count droplet)" -eq 0 ]
}

@test "destroy -y destroys droplets, volumes and VPC, removes state" {
	run $DO provision
	[ "$status" -eq 0 ]
	_fast_teardown
	run $DO destroy -y
	[ "$status" -eq 0 ]
	[ "$(_count droplet)" -eq 0 ]
	[ "$(_count volume)" -eq 0 ]
	[ "$(_count vpc)" -eq 0 ]
	[ ! -f "$CONFIG_DIR/state.prod" ]
}

@test "destroy deletes volumes only AFTER droplets report gone (Bug 1 ordering)" {
	run $DO provision
	[ "$status" -eq 0 ]
	_fast_teardown
	export DOCTL_DROPLET_LINGER=2
	: >"$REG/calls"
	run $DO destroy -y
	[ "$status" -eq 0 ]
	# In the calls log, a `droplet get` (the poll) must appear before the first
	# `volume delete` — i.e. we waited for the droplet before touching volumes.
	get_line="$(grep -n 'compute droplet get' "$REG/calls" | head -1 | cut -d: -f1)"
	vol_line="$(grep -n 'compute volume delete' "$REG/calls" | head -1 | cut -d: -f1)"
	[ -n "$get_line" ]
	[ -n "$vol_line" ]
	[ "$get_line" -lt "$vol_line" ]
}

@test "destroy tolerates a non-deletable default VPC (Bug 2)" {
	run $DO provision
	[ "$status" -eq 0 ]
	_fast_teardown
	export DOCTL_VPC_DEFAULT=1   # `vpcs delete` returns 403 "Can not delete default VPCs"
	run $DO destroy -y
	# Still succeeds; volumes + state gone, the free default VPC is left in place.
	[ "$status" -eq 0 ]
	[ "$(_count volume)" -eq 0 ]
	[ "$(_count vpc)" -eq 1 ]
	[ ! -f "$CONFIG_DIR/state.prod" ]
	echo "$output" | grep -qi "default vpc"
}

@test "destroy without -y proceeds when the user confirms with 'yes'" {
	run $DO provision
	[ "$status" -eq 0 ]
	_fast_teardown
	run bash -c "printf 'yes\n' | $DO destroy"
	[ "$status" -eq 0 ]
	[ "$(_count droplet)" -eq 0 ]
	[ "$(_count volume)" -eq 0 ]
	[ ! -f "$CONFIG_DIR/state.prod" ]
}

@test "destroy without -y aborts and deletes nothing when not confirmed" {
	run $DO provision
	[ "$status" -eq 0 ]
	_fast_teardown
	run bash -c "printf '\n' | $DO destroy"
	[ "$status" -ne 0 ]
	# Nothing was touched.
	[ "$(_count droplet)" -eq 2 ]
	[ "$(_count volume)" -eq 2 ]
	[ "$(_count vpc)" -eq 1 ]
	[ -f "$CONFIG_DIR/state.prod" ]
}

@test "stop with no state is a no-op (exit 0)" {
	run $DO stop
	[ "$status" -eq 0 ]
}

@test "destroy with no state is a no-op (exit 0)" {
	run $DO destroy -y
	[ "$status" -eq 0 ]
}

# --- misc -------------------------------------------------------------------

@test "stop and destroy are listed in usage; provision/deprovision are not" {
	run $DO --help
	[ "$status" -eq 0 ]
	# Public teardown surface (F8) IS listed as a command row.
	echo "$output" | grep -qE '^[[:space:]]+stop\b'
	echo "$output" | grep -qE '^[[:space:]]+destroy\b'
	# Hidden low-level `provision` and the retired `deprovision` are NOT command rows.
	echo "$output" | grep -qE '^[[:space:]]+de?provision\b' && return 1
	true
}

@test "deprovision has been removed (unknown command, exit 2)" {
	run $DO deprovision
	[ "$status" -eq 2 ]
}

@test "provision runs under zsh" {
	if ! command -v zsh >/dev/null 2>&1; then skip "zsh not installed"; fi
	run zsh ./bin/digital-ocean provision
	[ "$status" -eq 0 ]
}
