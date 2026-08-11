#!/usr/bin/env bats
#
# Fast/hermetic tests for infra/provision-ollama-cpu.sh (#18). This is the CPU
# backend's Ollama provisioner — same shape as provision-gpu.sh but WITHOUT the
# NVIDIA driver assertion (a plain Ubuntu CPU droplet). Runs as root on the
# Ollama node, invoked over SSH by `start`. Every Ubuntu boundary — the Ollama
# install (curl | sh), systemd, chown, and the block volume — is PATH-shimmed,
# and all paths are redirected into $BATS_TEST_TMPDIR.
#
# The un-mocked counterpart runs the script in a real ubuntu:22.04 container
# (tests/integration/provision.bats); the private-IP Ollama bind + real service
# start are proven at the billable CPU live VERIFY (#18/#19).
#
# NOTE: substring checks use `grep -q` (bats ignores a failed mid-test `[[ ]]`).

CPU=infra/provision-ollama-cpu.sh

setup() {
	SHIM="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$SHIM"

	export MODELS_MOUNT="$BATS_TEST_TMPDIR/mnt/models"
	export FSTAB_FILE="$BATS_TEST_TMPDIR/fstab"
	export SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd"
	: >"$FSTAB_FILE"

	export MODELS_DEVICE="$BATS_TEST_TMPDIR/dev-models"
	: >"$MODELS_DEVICE"

	# `start` binds Ollama to the node's PRIVATE VPC IP (#19), not 0.0.0.0.
	export OLLAMA_HOST="10.10.0.20:11434"

	export CURL_MARKER="$BATS_TEST_TMPDIR/curl.marker"
	export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
	export CHOWN_LOG="$BATS_TEST_TMPDIR/chown.log"
	export MKFS_MARKER="$BATS_TEST_TMPDIR/mkfs.marker"

	_shim_present curl "touch \"\$CURL_MARKER\""  # records the install fetch
	_shim_present sh ""                            # consumes the piped installer
	_shim_present systemctl "echo \"systemctl \$*\" >>\"\$SYSTEMCTL_LOG\""
	_shim_present chown "echo \"chown \$*\" >>\"\$CHOWN_LOG\""
	_shim_blkid
	_shim_present mkfs.ext4 "touch \"\$MKFS_MARKER\""
	_shim_present mount ""
	_shim_present mountpoint "exit 1"

	export PATH="$SHIM:/usr/bin:/bin"
}

_shim_present() {
	{ printf '#!/usr/bin/env bash\n'; printf '%s\n' "$2"; printf 'exit 0\n'; } >"$SHIM/$1"
	chmod +x "$SHIM/$1"
}

_shim_blkid() {
	cat >"$SHIM/blkid" <<'EOF'
#!/usr/bin/env bash
if [ -n "${BLKID_HAS_FS:-}" ]; then
	echo "$1: TYPE=\"ext4\""
	exit 0
fi
exit 2
EOF
	chmod +x "$SHIM/blkid"
}

@test "cpu-ollama: --help prints usage and exits 0" {
	run bash "$CPU" --help
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "provision-ollama-cpu"
}

@test "cpu-ollama: succeeds on a plain Ubuntu box with NO nvidia-smi present" {
	# No nvidia-smi shim at all — the CPU provisioner must not require a GPU.
	run bash "$CPU"
	[ "$status" -eq 0 ]
}

@test "cpu-ollama: writes a systemd drop-in binding Ollama to the private host + models volume" {
	run bash "$CPU"
	[ "$status" -eq 0 ]
	override="$SYSTEMD_DIR/ollama.service.d/override.conf"
	[ -f "$override" ]
	grep -q "OLLAMA_MODELS=$MODELS_MOUNT" "$override"
	# The private-IP bind (#19), NOT 0.0.0.0.
	grep -q "OLLAMA_HOST=10.10.0.20:11434" "$override"
	run grep -q "OLLAMA_HOST=0.0.0.0" "$override"
	[ "$status" -ne 0 ]
}

@test "cpu-ollama: installs Ollama when it is absent" {
	run bash "$CPU"
	[ "$status" -eq 0 ]
	[ -f "$CURL_MARKER" ]
}

@test "cpu-ollama: skips the Ollama install when it is already present" {
	_shim_present ollama ""   # ollama already on PATH
	run bash "$CPU"
	[ "$status" -eq 0 ]
	[ ! -f "$CURL_MARKER" ]
}

@test "cpu-ollama: gives the ollama user ownership of the models volume" {
	run bash "$CPU"
	[ "$status" -eq 0 ]
	grep -q "ollama:ollama $MODELS_MOUNT" "$CHOWN_LOG"
}

@test "cpu-ollama: reloads systemd and (re)starts the ollama service" {
	run bash "$CPU"
	[ "$status" -eq 0 ]
	grep -q "daemon-reload" "$SYSTEMCTL_LOG"
	grep -qE "restart ollama|enable" "$SYSTEMCTL_LOG"
}

@test "cpu-ollama: writes the DO device-path fstab line for the models volume once" {
	run bash "$CPU"
	[ "$status" -eq 0 ]
	grep -q "$MODELS_DEVICE $MODELS_MOUNT ext4 defaults,nofail,discard,noatime 0 2" "$FSTAB_FILE"
	run bash "$CPU"
	[ "$status" -eq 0 ]
	run grep -c "$MODELS_MOUNT ext4" "$FSTAB_FILE"
	[ "$output" -eq 1 ]
}
