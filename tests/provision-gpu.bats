#!/usr/bin/env bats
#
# Fast/hermetic tests for infra/provision-gpu.sh (F5). Runs as root on a fresh
# Ubuntu GPU droplet (invoked over SSH by F7). Every Ubuntu/GPU boundary —
# nvidia-smi, the Ollama install (curl | sh), systemd, chown, and the block
# volume — is PATH-shimmed, and all paths are redirected into $BATS_TEST_TMPDIR.
# The un-mocked counterpart runs the script in a real ubuntu:22.04 container
# (tests/integration/provision.bats), where the nvidia assertion's NEGATIVE path
# fires for real (no GPU); the GPU-present positive path is deferred to F7.
#
# NOTE: substring checks use `grep -q` (bats ignores a failed mid-test `[[ ]]`).

GPU=infra/provision-gpu.sh

setup() {
	SHIM="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$SHIM"

	export MODELS_MOUNT="$BATS_TEST_TMPDIR/mnt/models"
	export FSTAB_FILE="$BATS_TEST_TMPDIR/fstab"
	export SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd"
	: >"$FSTAB_FILE"

	export MODELS_DEVICE="$BATS_TEST_TMPDIR/dev-models"
	: >"$MODELS_DEVICE"

	# Keep the nvidia poll instantaneous in tests.
	export NVIDIA_WAIT_SECS=0

	export CURL_MARKER="$BATS_TEST_TMPDIR/curl.marker"
	export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
	export CHOWN_LOG="$BATS_TEST_TMPDIR/chown.log"
	export MKFS_MARKER="$BATS_TEST_TMPDIR/mkfs.marker"

	_shim_present nvidia-smi ""                 # default: GPU driver present
	_shim_present curl "touch \"\$CURL_MARKER\""  # records the install fetch
	_shim_present sh ""                          # consumes the piped installer
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

@test "gpu: --help prints usage and exits 0" {
	run bash "$GPU" --help
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "provision-gpu"
}

@test "gpu: succeeds when the NVIDIA driver is present" {
	run bash "$GPU"
	[ "$status" -eq 0 ]
}

@test "gpu: fails fast when nvidia-smi is missing or the driver is not ready" {
	_shim_present nvidia-smi "exit 1"   # driver never comes up
	run bash "$GPU"
	[ "$status" -ne 0 ]
	echo "$output" | grep -qi "nvidia"
}

@test "gpu: writes a systemd drop-in pointing Ollama at the models volume + VPC host" {
	run bash "$GPU"
	[ "$status" -eq 0 ]
	override="$SYSTEMD_DIR/ollama.service.d/override.conf"
	[ -f "$override" ]
	grep -q "OLLAMA_MODELS=$MODELS_MOUNT" "$override"
	grep -q "OLLAMA_HOST=0.0.0.0:11434" "$override"
}

@test "gpu: installs Ollama when it is absent" {
	run bash "$GPU"
	[ "$status" -eq 0 ]
	[ -f "$CURL_MARKER" ]
}

@test "gpu: skips the Ollama install when it is already present" {
	_shim_present ollama ""   # ollama already on PATH
	run bash "$GPU"
	[ "$status" -eq 0 ]
	[ ! -f "$CURL_MARKER" ]
}

@test "gpu: gives the ollama user ownership of the models volume" {
	run bash "$GPU"
	[ "$status" -eq 0 ]
	grep -q "ollama:ollama $MODELS_MOUNT" "$CHOWN_LOG"
}

@test "gpu: reloads systemd and (re)starts the ollama service" {
	run bash "$GPU"
	[ "$status" -eq 0 ]
	grep -q "daemon-reload" "$SYSTEMCTL_LOG"
	grep -qE "restart ollama|enable" "$SYSTEMCTL_LOG"
}

@test "gpu: writes the DO device-path fstab line for the models volume once" {
	run bash "$GPU"
	[ "$status" -eq 0 ]
	grep -q "$MODELS_DEVICE $MODELS_MOUNT ext4 defaults,nofail,discard,noatime 0 2" "$FSTAB_FILE"
	run bash "$GPU"
	[ "$status" -eq 0 ]
	run grep -c "$MODELS_MOUNT ext4" "$FSTAB_FILE"
	[ "$output" -eq 1 ]
}
