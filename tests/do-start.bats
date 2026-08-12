#!/usr/bin/env bats
#
# Fast/hermetic tests for `digital-ocean start` (F7) — the end-to-end orchestration.
# Every external boundary is PATH-shimmed so the whole flow runs offline and free:
#   - doctl : the F6 stateful stub (VPC/volume/droplet/ssh-key/attach) + firewall verbs.
#   - ssh   : records the remote command it was asked to run (per host) and can be
#             told to "fail SSH until ready" so we can exercise the wait/failure paths.
#   - scp / rsync : record src+dst so we can assert code + creds transfer.
# The stubs write to $LOG/* so tests assert what ran, in what order, with what env.
#
# The un-mocked counterpart is tests/integration/do-start.bats (DO_REAL_START=1) plus
# the billable live VERIFY (real GPU/ssh/Ollama) — the boundaries a stub can't prove.
#
# NOTE: bats silently ignores a mid-test `[[ ]]` that returns false, so substring
# checks use `grep -q` (a simple command bats DOES catch).

DO=./bin/digital-ocean

setup() {
	CONFIG_DIR="$BATS_TEST_TMPDIR/do"
	SHIM="$BATS_TEST_TMPDIR/bin"
	REG="$BATS_TEST_TMPDIR/reg"
	LOG="$BATS_TEST_TMPDIR/log"
	mkdir -p "$CONFIG_DIR" "$SHIM" "$REG" "$LOG"

	export DO_CONFIG_DIR="$CONFIG_DIR"
	export DOCTL_REG="$REG"
	export DO_SHIM_LOG="$LOG"
	# Keep the health/SSH waits fast in the hermetic lane.
	export DO_SSH_WAIT_SECS=3
	export DO_HEALTH_WAIT_SECS=3
	export DO_RETRY_SLEEP=0

	_write_config
	_write_creds
	_shim_doctl
	_shim_ssh_scp_rsync
	export PATH="$SHIM:/usr/bin:/bin"
}

# A valid .do/config as F4's `setup` would write it.
_write_config() {
	cat >"$CONFIG_DIR/config" <<EOF
DO_REGION='blr1'
DO_CPU_SIZE='s-2vcpu-4gb'
DO_GPU_SIZE='gpu-6000adax1-48gb'
DO_SSH_KEY_NAME='my-mac'
APP_CREDENTIALS_FILE='$CONFIG_DIR/credentials'
EOF
	# #27 (F11): the model is a per-app fact, read from the manifest (--app-dir demo),
	# NOT from the infra config — so it is deliberately absent above.
}

_write_creds() {
	printf 'ACME_API_KEY=shhh\n' >"$CONFIG_DIR/credentials"
}

# The F6 stateful doctl stub, extended with `vpcs get` (IP range) and the
# `compute firewall` verbs (create/list/add-droplets). Registry lines:
#   "TYPE NAME ID PUB PRIV"  in $DOCTL_REG/resources   (PUB/PRIV '-' for non-droplets)
#   "VOLID DROPID"           in $DOCTL_REG/attach
# All invocations are appended to $DOCTL_REG/calls.
_shim_doctl() {
	cat >"$SHIM/doctl" <<'EOF'
#!/usr/bin/env bash
REG="${DOCTL_REG:?}"; RES="$REG/resources"; ATT="$REG/attach"; CALLS="$REG/calls"; FW="$REG/fw"
: >>"$RES"; : >>"$ATT"; : >>"$CALLS"; : >>"$FW"
printf '%s\n' "$*" >>"$CALLS"

# Real doctl's `vpcs create` does NOT support --format (unlike volume/droplet
# create) — mimic that failure so ensure_vpc can't regress to passing it (#18 VERIFY).
case "$*" in "vpcs create"*--format*) echo "Error: unknown flag: --format" >&2; exit 1;; esac

name=""; dropids=""; args=()
while [ $# -gt 0 ]; do
	case "$1" in
	--name) name="$2"; shift 2;;
	--droplet-ids) dropids="$2"; shift 2;;
	--region|--size|--image|--ssh-keys|--vpc-uuid|--format|--fs-type|--inbound-rules|--outbound-rules) shift 2;;
	--no-header|--wait|--force) shift;;
	*) args+=("$1"); shift;;
	esac
done

_id() { printf 'id-%s' "$1"; }
_ips() {
	case "$1" in
	*-cpu) echo "203.0.113.10 10.10.0.10";;
	*-gpu) echo "203.0.113.20 10.10.0.20";;
	*) echo "203.0.113.99 10.10.0.99";;
	esac
}
_find_id() { awk -v t="$1" -v n="$2" '$1==t && $2==n{print $3; exit}' "$RES"; }
_add() { printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" >>"$RES"; }
_del_by_id() { grep -v " $1 " "$RES" >"$RES.tmp" 2>/dev/null; mv "$RES.tmp" "$RES"; }

# Recover the value of a flag from the ORIGINAL argv (we consumed them above).
_flagval() { printf '%s\n' "$DOCTL_ARGV" | tr ' ' '\n' >/dev/null 2>&1; }

key="${args[0]:-} ${args[1]:-}"
case "$key" in
"vpcs list")
	awk '$1=="vpc"{print $2, $3}' "$RES";;
"vpcs create")
	id="$(_id "$name")"; [ -n "$(_find_id vpc "$name")" ] || _add vpc "$name" "$id" - -; printf '%s\n' "$id";;
"vpcs get")
	# `vpcs get <id> --format IPRange --no-header` : deterministic range.
	echo "10.10.0.0/20";;
"vpcs delete")
	_del_by_id "${args[2]}";;
"compute volume")
	case "${args[2]:-}" in
	list) awk '$1=="volume"{print $2, $3}' "$RES";;
	create) vn="${args[3]}"; id="$(_id "$vn")"; [ -n "$(_find_id volume "$vn")" ] || _add volume "$vn" "$id" - -; printf '%s\n' "$id";;
	delete) _del_by_id "${args[3]}";;
	get) awk -v v="${args[3]}" '$1==v{print $2}' "$ATT";;
	esac;;
"compute volume-action")
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
	printf '%s %s\n' "${DOCTL_KEY_NAME:-my-mac}" "111";;
"compute firewall")
	case "${args[2]:-}" in
	list) awk '$1=="fw"{print $2, $3}' "$RES";;
	create)
		# Simulate a token without firewall scope: create is denied (no ID, non-zero).
		if [ -n "${DOCTL_FW_DENY:-}" ]; then echo "Error: forbidden (firewall scope)" >&2; exit 1; fi
		fn="$name"; id="$(_id "$fn")"; [ -n "$(_find_id fw "$fn")" ] || _add fw "$fn" "$id" - -
		printf 'create %s %s\n' "$fn" "$id" >>"$FW"; printf '%s\n' "$id";;
	"add-droplets") printf 'add-droplets %s\n' "$dropids" >>"$FW";;
	get) fn="${args[3]}"; _find_id fw "$fn";;
	esac;;
"account get") exit 0;;
esac
exit 0
EOF
	chmod +x "$SHIM/doctl"
}

# ssh / scp / rsync stubs. Each appends a line to its own log so tests can assert
# the remote commands, transfers, and per-host env wiring. `ssh` honours a
# "not-ready" gate file to simulate a droplet whose SSH isn't up yet, and a
# "fail marker" so a specific remote command can be made to fail.
_shim_ssh_scp_rsync() {
	# ssh: args look like `ssh <opts...> root@HOST <remote command...>`.
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
# Simulate "SSH not ready yet" for the first N connects if the gate file exists.
if [ -f "$LOG/ssh_notready" ]; then
	n="$(cat "$LOG/ssh_notready" 2>/dev/null || echo 0)"
	if [ "$n" -gt 0 ]; then
		printf '%s\n' "$((n - 1))" >"$LOG/ssh_notready"
		echo "ssh: connect to host $host: Connection refused" >&2
		exit 255
	fi
fi
printf '%s | %s\n' "$host" "${cmd[*]}" >>"$LOG/ssh"
# A remote command containing a token listed in ssh_fail fails (non-zero).
if [ -f "$LOG/ssh_fail" ] && printf '%s' "${cmd[*]}" | grep -qf "$LOG/ssh_fail"; then
	exit 1
fi
exit 0
EOF
	chmod +x "$SHIM/ssh"

	cat >"$SHIM/scp" <<'EOF'
#!/usr/bin/env bash
LOG="${DO_SHIM_LOG:?}"
args=()
while [ $# -gt 0 ]; do case "$1" in -o|-i) shift 2;; -*) shift;; *) args+=("$1"); shift;; esac; done
printf '%s\n' "${args[*]}" >>"$LOG/scp"
exit 0
EOF
	chmod +x "$SHIM/scp"

	cat >"$SHIM/rsync" <<'EOF'
#!/usr/bin/env bash
LOG="${DO_SHIM_LOG:?}"
# Simulate a transient reset/stall for the first N calls if the gate file exists,
# so the CLI's _retry wrapper can be exercised.
if [ -f "$LOG/rsync_fail" ]; then
	n="$(cat "$LOG/rsync_fail" 2>/dev/null || echo 0)"
	if [ "$n" -gt 0 ]; then
		printf '%s\n' "$((n - 1))" >"$LOG/rsync_fail"
		echo "rsync: connection unexpectedly closed" >&2
		exit 12
	fi
fi
args=()
while [ $# -gt 0 ]; do case "$1" in -e) shift 2;; -*) shift;; *) args+=("$1"); shift;; esac; done
printf '%s\n' "${args[*]}" >>"$LOG/rsync"
exit 0
EOF
	chmod +x "$SHIM/rsync"
}

# Convenience greppers over the ssh log. The ssh stub logs "root@HOST | <cmd>";
# each remote command is kept single-line by the CLI, so a bare-IP grep isolates
# the commands sent to one droplet.
_ssh_to() { grep "$1" "$LOG/ssh" 2>/dev/null; }
_count() { grep -c "^$1 " "$REG/resources" 2>/dev/null || true; }

# --- happy path -------------------------------------------------------------

@test "start provisions, deploys, health-checks and prints the public URL (exit 0)" {
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	# stdout carries the public UI URL (data) — CPU public IP : 5000.
	echo "$output" | grep -q "http://203.0.113.10:5000"
	# and paste-ready ssh commands for both droplets.
	echo "$output" | grep -q "ssh root@203.0.113.10"
	echo "$output" | grep -q "ssh root@203.0.113.20"
}

@test "start reuses F6 provisioning — VPC, volumes, droplets, attach, state" {
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	[ -f "$CONFIG_DIR/state" ]
	[ "$(_count droplet)" -eq 2 ]
	[ "$(_count volume)" -eq 2 ]
	grep -q "id-hello-do-data id-hello-do-cpu" "$REG/attach"
	grep -q "id-hello-do-models id-hello-do-gpu" "$REG/attach"
}

# --- firewall: optional (#19) -----------------------------------------------

@test "start skips DO firewalls by default (private-IP bind is the control) and still succeeds" {
	# _write_config sets no DO_ENABLE_FIREWALL, so the default (0/off) applies.
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	# No firewall was created or assigned…
	[ ! -s "$REG/fw" ] || run grep -q "create hello-do" "$REG/fw"
	run grep -E "firewall create" "$REG/calls"
	[ "$status" -ne 0 ]
	# …and the firewall IDs in state are empty.
	grep -q "DO_CPU_FW_ID=''" "$CONFIG_DIR/state"
	grep -q "DO_GPU_FW_ID=''" "$CONFIG_DIR/state"
}

@test "start ensures two firewalls when DO_ENABLE_FIREWALL=1: cpu (5000+22 public) and gpu (11434 from VPC)" {
	DO_ENABLE_FIREWALL=1 run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	# Both firewalls created and recorded in state.
	grep -q "create hello-do-cpu-fw" "$REG/fw"
	grep -q "create hello-do-gpu-fw" "$REG/fw"
	grep -q "DO_CPU_FW_ID='id-hello-do-cpu-fw'" "$CONFIG_DIR/state"
	grep -q "DO_GPU_FW_ID='id-hello-do-gpu-fw'" "$CONFIG_DIR/state"
	# GPU firewall's 11434 rule is sourced from the VPC IP range, not 0.0.0.0/0.
	gpu_create="$(grep -E "firewall create .*hello-do-gpu-fw" "$REG/calls")"
	echo "$gpu_create" | grep -q "ports:11434,address:10.10.0.0/20"
	echo "$gpu_create" | grep -qv "ports:11434,address:0.0.0.0/0"
	# CPU firewall exposes 5000 publicly.
	cpu_create="$(grep -E "firewall create .*hello-do-cpu-fw" "$REG/calls")"
	echo "$cpu_create" | grep -q "ports:5000,address:0.0.0.0/0"
	# Each firewall is assigned its droplet.
	grep -q "add-droplets id-hello-do-cpu" "$REG/fw"
	grep -q "add-droplets id-hello-do-gpu" "$REG/fw"
}

@test "start hard-fails when a firewall is requested (=1) but the token lacks scope" {
	export DOCTL_FW_DENY=1
	DO_ENABLE_FIREWALL=1 run $DO --app-dir demo start
	[ "$status" -ne 0 ]
	# Points the operator at the scope issue (#16) rather than silently continuing.
	echo "$output" | grep -qi "firewall"
}

@test "start rsyncs the app to /opt/app/app and infra to /opt/app on BOTH droplets" {
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	# #27: app CODE lands at /opt/app/app (not a demo/-named path); infra is tool-owned.
	grep -q "203.0.113.10:/opt/app/app" "$LOG/rsync"
	grep -q "203.0.113.20:/opt/app/app" "$LOG/rsync"
	grep -q "infra" "$LOG/rsync"
}

# --- Ollama node: backend selection (#18) + private-IP bind (#19) -----------

@test "default (cpu) backend: provisions the CPU Ollama node and pulls the model" {
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	# The Ollama node (the DO_GPU_* droplet) runs the CPU provisioning script — NOT the GPU one.
	node="$(_ssh_to 203.0.113.20)"
	echo "$node" | grep -q "provision-ollama-cpu.sh"
	echo "$node" | grep -qv "provision-gpu.sh"
	echo "$node" | grep -q "MODELS_VOLUME_NAME=hello-do-models"
	# C8: ollama pull of the configured model, on the Ollama node.
	echo "$node" | grep -q "ollama pull llama3.2:1b"
}

@test "cpu backend: Ollama is bound to the node's PRIVATE VPC IP, not 0.0.0.0 (#19)" {
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	node="$(_ssh_to 203.0.113.20)"
	# The provisioning step binds Ollama to the private IP…
	echo "$node" | grep -q "OLLAMA_HOST=10.10.0.20:11434"
	echo "$node" | grep -qv "OLLAMA_HOST=0.0.0.0"
	# …and `ollama pull` targets the same private host (the CLI defaults to loopback).
	echo "$node" | grep -q "OLLAMA_HOST=10.10.0.20:11434 ollama pull"
}

@test "gpu backend: provisions the GPU Ollama node with provision-gpu.sh" {
	OLLAMA_BACKEND=gpu run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	node="$(_ssh_to 203.0.113.20)"
	echo "$node" | grep -q "provision-gpu.sh"
	echo "$node" | grep -qv "provision-ollama-cpu.sh"
	echo "$node" | grep -q "OLLAMA_HOST=10.10.0.20:11434"
}

@test "cpu backend: the Ollama droplet is created with the CPU size (DO_OLLAMA_CPU_SIZE default)" {
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	node_create="$(grep -E "droplet create hello-do-gpu" "$REG/calls")"
	echo "$node_create" | grep -q "s-8vcpu-16gb-amd"
	echo "$node_create" | grep -qv "gpu-6000adax1-48gb"
}

@test "gpu backend: the Ollama droplet is created with the GPU size" {
	OLLAMA_BACKEND=gpu run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	node_create="$(grep -E "droplet create hello-do-gpu" "$REG/calls")"
	echo "$node_create" | grep -q "gpu-6000adax1-48gb"
}

@test "start runs provision-cpu.sh with the data volume + manifest requirements on the CPU droplet" {
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	cpu="$(_ssh_to 203.0.113.10)"
	echo "$cpu" | grep -q "provision-cpu.sh"
	echo "$cpu" | grep -q "DATA_VOLUME_NAME=hello-do-data"
	# #27: the CLI drives the tool-owned infra script with the manifest's
	# requirements at the app's /opt/app/app location (no hardcoded demo/ path).
	echo "$cpu" | grep -q "REQUIREMENTS_FILE=/opt/app/app/requirements.txt"
}

@test "start scps the credentials file to /etc/app/credentials on the CPU" {
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	# scp of the local creds file to the CPU's /etc/app/credentials.
	grep -q "credentials" "$LOG/scp"
	grep -q "203.0.113.10:/etc/app/credentials" "$LOG/scp"
}

@test "start deploys the app as a systemd unit with the explicit manifest env contract" {
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	cpu="$(_ssh_to 203.0.113.10)"
	# #27: NO demo-specific APP_ENV — the CLI sets the contract explicitly instead.
	[ "$(echo "$cpu" | grep -c "APP_ENV=")" -eq 0 ]
	# Explicit bind + private-IP Ollama URL (ADR-0007) + manifest port/model.
	echo "$cpu" | grep -q "HOST=0.0.0.0"
	echo "$cpu" | grep -q "PORT=5000"
	echo "$cpu" | grep -q "OLLAMA_URL=http://10.10.0.20:11434"
	echo "$cpu" | grep -q "OLLAMA_MODEL=llama3.2:1b"
	# ExecStart runs the manifest entrypoint from the app's /opt/app/app location.
	echo "$cpu" | grep -q "/opt/app/app/app.py"
	# Deployed via systemd (app.service enabled/started), not nohup.
	echo "$cpu" | grep -qE "systemctl (enable|restart|start).*app"
}

@test "start records the app port + health path in .do/state (F9 reads them)" {
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	# #27: the deployed app facts land in state so status/logs stay manifest-free.
	grep -q "APP_PORT='5000'" "$CONFIG_DIR/state"
	grep -q "APP_HEALTH_PATH='/health'" "$CONFIG_DIR/state"
}

@test "start health-checks Ollama (private) and the app /health, then reports healthy" {
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	cpu="$(_ssh_to 203.0.113.10)"
	# Ollama reachability is checked over the PRIVATE IP from the CPU side.
	echo "$cpu" | grep -q "10.10.0.20:11434/api/tags"
	# App health endpoint is probed.
	echo "$cpu$output" | grep -q "5000/health"
}

# --- idempotency ------------------------------------------------------------

@test "re-running start adopts everything — no duplicate resources, no new create" {
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	: >"$REG/calls"
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	[ "$(_count droplet)" -eq 2 ]
	[ "$(_count volume)" -eq 2 ]
	# Firewalls are off by default (#19), so none exist to duplicate either.
	[ "$(_count fw)" -eq 0 ]
	run grep -E "(vpcs create|volume create|droplet create|firewall create)" "$REG/calls"
	[ "$status" -ne 0 ]
}

# --- failure paths ----------------------------------------------------------

@test "start without a config fails and provisions nothing" {
	rm -f "$CONFIG_DIR/config"
	run $DO --app-dir demo start
	[ "$status" -ne 0 ]
	echo "$output" | grep -q "setup"
	run grep -E "create" "$REG/calls"
	[ "$status" -ne 0 ]
}

@test "start retries a transient rsync reset/stall and still succeeds" {
	# Fresh droplets can reset/stall the first transfer under cloud-init; the CLI
	# must retry rather than fail the whole start (found at #18 live VERIFY).
	printf '2\n' >"$LOG/rsync_fail"   # first two rsync attempts fail, then succeed
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
	# The sync still landed on both droplets after the retries.
	grep -q "203.0.113.10:/opt/app" "$LOG/rsync"
	grep -q "203.0.113.20:/opt/app" "$LOG/rsync"
}

@test "start gives up if rsync never succeeds (bounded retries, non-zero)" {
	printf '99\n' >"$LOG/rsync_fail"   # fail far more than the retry budget
	run $DO --app-dir demo start
	[ "$status" -ne 0 ]
}

@test "start waits for SSH to come up, then proceeds (exit 0)" {
	# First two ssh connects are refused; the wait loop must retry to success.
	printf '2\n' >"$LOG/ssh_notready"
	run $DO --app-dir demo start
	[ "$status" -eq 0 ]
}

@test "start fails (non-zero) when SSH never becomes reachable" {
	# Refuse far more connects than the (small) wait budget allows.
	printf '9999\n' >"$LOG/ssh_notready"
	run $DO --app-dir demo start
	[ "$status" -ne 0 ]
	echo "$output" | grep -qi "ssh"
}

@test "start fails (non-zero) when the app health check never passes" {
	# Make the app-health probe fail on the remote side.
	printf '5000/health\n' >"$LOG/ssh_fail"
	run $DO --app-dir demo start
	[ "$status" -ne 0 ]
	echo "$output" | grep -qi "health"
}

# --- misc -------------------------------------------------------------------

@test "start is listed in usage (public surface, unlike provision)" {
	run $DO --help
	[ "$status" -eq 0 ]
	echo "$output" | grep -qE '^[[:space:]]+start\b'
}

@test "start runs under zsh" {
	if ! command -v zsh >/dev/null 2>&1; then skip "zsh not installed"; fi
	run zsh ./bin/digital-ocean --app-dir demo start
	[ "$status" -eq 0 ]
}
