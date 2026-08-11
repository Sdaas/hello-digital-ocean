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
	export APT_LOG="$BATS_TEST_TMPDIR/apt.log"

	# Driver presence is modelled by a marker file: nvidia-smi succeeds iff the
	# marker exists, and the `ubuntu-drivers` install creates it. Default: present,
	# so the install step is a no-op (matching a droplet whose driver is up).
	export DRIVER_MARKER="$BATS_TEST_TMPDIR/driver.installed"
	: >"$DRIVER_MARKER"

	_shim_nvidia                                 # nvidia-smi: 0 iff DRIVER_MARKER exists
	_shim_present apt-get "echo \"apt-get \$*\" >>\"\$APT_LOG\""
	_shim_present ubuntu-drivers "echo \"ubuntu-drivers \$*\" >>\"\$APT_LOG\"; touch \"\$DRIVER_MARKER\""
	_shim_present modprobe "echo \"modprobe \$*\" >>\"\$APT_LOG\""
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

# nvidia-smi that mirrors driver state: succeeds only once DRIVER_MARKER exists.
_shim_nvidia() {
	cat >"$SHIM/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
[ -f "$DRIVER_MARKER" ] && exit 0
exit 1
EOF
	chmod +x "$SHIM/nvidia-smi"
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

@test "gpu: installs the NVIDIA driver before asserting when it is absent" {
	rm -f "$DRIVER_MARKER"            # plain Ubuntu image: no driver yet
	run bash "$GPU"
	[ "$status" -eq 0 ]              # install brought the driver up, assert passed
	grep -q "^apt-get " "$APT_LOG"   # ran apt
	grep -q "^ubuntu-drivers " "$APT_LOG"
}

@test "gpu: skips the driver install when nvidia-smi is already healthy" {
	run bash "$GPU"                  # DRIVER_MARKER present by default
	[ "$status" -eq 0 ]
	[ ! -s "$APT_LOG" ]             # idempotent: no apt / ubuntu-drivers work
}

@test "gpu: NVIDIA_INSTALL=0 skips the install and asserts only (integration guard)" {
	rm -f "$DRIVER_MARKER"
	NVIDIA_INSTALL=0 run bash "$GPU"
	[ "$status" -ne 0 ]             # no install, no GPU → fail fast
	[ ! -s "$APT_LOG" ]            # never touched apt
	echo "$output" | grep -qi "nvidia"
}

@test "gpu: fails when the driver never comes up even after an install attempt" {
	rm -f "$DRIVER_MARKER"
	# A broken install that does not bring nvidia-smi up: driver stays absent.
	_shim_present ubuntu-drivers "echo \"ubuntu-drivers \$*\" >>\"\$APT_LOG\""
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
