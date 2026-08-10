#!/usr/bin/env bats
#
# Fast/hermetic tests for infra/provision-cpu.sh (F5). This script runs as root
# on a fresh Ubuntu CPU droplet (invoked over SSH by F7), so every Ubuntu-only
# boundary — apt-get, the block-volume device + mkfs/mount/fstab, and
# python3/venv/pip — is PATH-shimmed and every path (/mnt/data, APP_DIR,
# /etc/fstab) is redirected into $BATS_TEST_TMPDIR. Nothing real runs here. The
# un-mocked counterpart runs the script in a real ubuntu:22.04 container
# (tests/integration/provision.bats); the volume-mount positive path is deferred
# to F7 (a real droplet with an attached volume).
#
# NOTE: bats silently ignores a mid-test `[[ ]]` that returns false, so
# substring checks use `grep -q` (a simple command bats DOES catch).

CPU=infra/provision-cpu.sh

setup() {
	SHIM="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$SHIM"

	# Redirect every filesystem target into the throwaway tmpdir.
	export APP_DIR="$BATS_TEST_TMPDIR/opt/app"
	export DATA_MOUNT="$BATS_TEST_TMPDIR/mnt/data"
	export FSTAB_FILE="$BATS_TEST_TMPDIR/fstab"
	export REQUIREMENTS_FILE="$APP_DIR/demo/requirements.txt"
	mkdir -p "$APP_DIR/demo"
	: >"$REQUIREMENTS_FILE"
	: >"$FSTAB_FILE"

	# A "device" the script will treat as the attached volume. -e is true, so the
	# mount branch runs; blkid/mkfs/mount are shimmed below.
	export DATA_DEVICE="$BATS_TEST_TMPDIR/dev-data"
	: >"$DATA_DEVICE"

	# Logs the shims append to, so tests can assert what got invoked.
	export APTLOG="$BATS_TEST_TMPDIR/apt.log"
	export PYLOG="$BATS_TEST_TMPDIR/py.log"
	export MOUNTLOG="$BATS_TEST_TMPDIR/mount.log"
	export MKFS_MARKER="$BATS_TEST_TMPDIR/mkfs.marker"

	_shim_apt
	_shim_python3
	_shim_blkid          # default: volume is UNFORMATTED
	_shim_present mkfs.ext4 "touch \"\$MKFS_MARKER\""
	_shim_present mount    "echo \"mount \$*\" >>\"\$MOUNTLOG\""
	_shim_present mountpoint "exit 1"   # never already mounted, so mount runs
	_shim_present chown ""

	export PATH="$SHIM:/usr/bin:/bin"
}

# _shim_present NAME BODY — a tiny shim whose body is BODY then exit 0.
_shim_present() {
	{ printf '#!/usr/bin/env bash\n'; printf '%s\n' "$2"; printf 'exit 0\n'; } >"$SHIM/$1"
	chmod +x "$SHIM/$1"
}

_shim_apt() {
	cat >"$SHIM/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >>"$APTLOG"
exit 0
EOF
	chmod +x "$SHIM/apt-get"
}

# blkid: exit 2 (no filesystem) by default; if BLKID_HAS_FS is set, report ext4.
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

# python3: `-m venv DIR` fabricates DIR/bin/python (which records pip calls);
# everything else is logged. Lets us assert venv creation + pip install without
# a real interpreter.
_shim_python3() {
	cat >"$SHIM/python3" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
	mkdir -p "$3/bin"
	cat >"$3/bin/python" <<'INNER'
#!/usr/bin/env bash
echo "python $*" >>"$PYLOG"
exit 0
INNER
	chmod +x "$3/bin/python"
	echo "venv $3" >>"$PYLOG"
	exit 0
fi
echo "python3 $*" >>"$PYLOG"
exit 0
EOF
	chmod +x "$SHIM/python3"
}

@test "cpu: --help prints usage and exits 0" {
	run bash "$CPU" --help
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "provision-cpu"
}

@test "cpu: installs the python/venv apt packages" {
	run bash "$CPU"
	[ "$status" -eq 0 ]
	grep -q "install" "$APTLOG"
	grep -q "python3-venv" "$APTLOG"
}

@test "cpu: creates the venv and pip-installs from the requirements file" {
	run bash "$CPU"
	[ "$status" -eq 0 ]
	grep -q "venv $APP_DIR/.venv" "$PYLOG"
	grep -q "pip install -r $REQUIREMENTS_FILE" "$PYLOG"
}

@test "cpu: formats the data volume only when it is unformatted" {
	run bash "$CPU"
	[ "$status" -eq 0 ]
	[ -f "$MKFS_MARKER" ]
}

@test "cpu: never reformats an already-formatted volume" {
	BLKID_HAS_FS=1 run bash "$CPU"
	[ "$status" -eq 0 ]
	[ ! -f "$MKFS_MARKER" ]
}

@test "cpu: writes the DO device-path fstab line with the recommended options" {
	run bash "$CPU"
	[ "$status" -eq 0 ]
	grep -q "$DATA_DEVICE $DATA_MOUNT ext4 defaults,nofail,discard,noatime 0 2" "$FSTAB_FILE"
}

@test "cpu: appends the fstab line exactly once across repeated runs" {
	run bash "$CPU"
	[ "$status" -eq 0 ]
	run bash "$CPU"
	[ "$status" -eq 0 ]
	run grep -c "$DATA_MOUNT ext4" "$FSTAB_FILE"
	[ "$output" -eq 1 ]
}

@test "cpu: creates the log dir on the data volume" {
	run bash "$CPU"
	[ "$status" -eq 0 ]
	[ -d "$DATA_MOUNT/logs" ]
}

@test "cpu: is idempotent — a second run still exits 0 and keeps the venv" {
	run bash "$CPU"
	[ "$status" -eq 0 ]
	rm -f "$PYLOG"
	run bash "$CPU"
	[ "$status" -eq 0 ]
	# venv already exists, so it is not recreated on the second run.
	run grep -c "venv $APP_DIR/.venv" "$PYLOG"
	[ "$output" -eq 0 ]
}
