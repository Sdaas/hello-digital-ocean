#!/usr/bin/env bash
#
# provision-cpu.sh — provision a fresh Ubuntu CPU droplet for the demo app (F5).
#
# Runs as root ON THE DROPLET, invoked over SSH by the `digital-ocean` CLI
# (F7) after each `start` — droplets are ephemeral (ADR-0001), so this reinstalls
# OS/app deps every time. It is IDEMPOTENT: re-running skips work already done.
#
# What it does:
#   1. apt: python3 + venv + pip.
#   2. Attach the data Block Storage volume at $DATA_MOUNT (/mnt/data):
#      create an ext4 filesystem ONLY if the volume is unformatted (never
#      reformat — the volume persists conversation history + logs across a
#      stop→start, ADR-0003), then mount it and record it in /etc/fstab using
#      DigitalOcean's recommended device-path line.
#   3. Create the log dir on the data volume (ADR-0003).
#   4. Build the Python venv and install $REQUIREMENTS_FILE (demo/requirements.txt).
#
# It does NOT deploy the app or copy credentials — that is F7. Configuration is
# via environment variables (see below); F7 exports them over SSH.
#
#   Env var            Default                              Meaning
#   APP_DIR            /opt/app                             where F7 puts the app
#   VENV_DIR           $APP_DIR/.venv                       Python venv location
#   REQUIREMENTS_FILE  $APP_DIR/demo/requirements.txt       pip -r target
#   DATA_MOUNT         /mnt/data                            data volume mountpoint
#   DATA_VOLUME_NAME   (unset)                              DO volume name → device
#   DATA_DEVICE        by-id path from DATA_VOLUME_NAME     block device to mount
#   LOG_DIR            $DATA_MOUNT/logs                     app log dir
#   FSTAB_FILE         /etc/fstab                           (overridable for tests)

set -euo pipefail

# --- config (env override > default) ----------------------------------------
APP_DIR="${APP_DIR:-/opt/app}"
VENV_DIR="${VENV_DIR:-$APP_DIR/.venv}"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-$APP_DIR/demo/requirements.txt}"
DATA_MOUNT="${DATA_MOUNT:-/mnt/data}"
DATA_VOLUME_NAME="${DATA_VOLUME_NAME:-}"
DATA_DEVICE="${DATA_DEVICE:-${DATA_VOLUME_NAME:+/dev/disk/by-id/scsi-0DO_Volume_$DATA_VOLUME_NAME}}"
LOG_DIR="${LOG_DIR:-$DATA_MOUNT/logs}"
FSTAB_FILE="${FSTAB_FILE:-/etc/fstab}"

# --- logging (leveled, to stderr; matches the digital-ocean CLI idiom) -------
LOG_LEVEL=INFO
log() {
	level="$1"; shift
	if [ "$level" = DEBUG ] && [ "$LOG_LEVEL" != DEBUG ]; then return 0; fi
	printf '%s %s provision-cpu: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}
log_debug() { log DEBUG "$@"; }
log_info()  { log INFO  "$@"; }
log_error() { log ERROR "$@"; }

usage() {
	cat <<EOF
Usage: provision-cpu.sh [--help] [--verbose]

Provision a fresh Ubuntu CPU droplet for the demo app: apt python deps, mount
the data volume at \$DATA_MOUNT (${DATA_MOUNT}), create the log dir, and build
the venv from \$REQUIREMENTS_FILE. Idempotent; run as root over SSH (F7).
Configured by environment variables — see the header of this script.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--help | -h) usage; exit 0 ;;
	--verbose | -v) LOG_LEVEL=DEBUG ;;
	*) log_error "unknown argument: $1 (try --help)"; exit 2 ;;
	esac
	shift
done

# --- helpers ----------------------------------------------------------------

# mount_volume DEVICE MOUNTPOINT — format-if-empty, mount, and persist in fstab
# using DigitalOcean's recommended by-id device-path line. Idempotent and safe:
# it never reformats a volume that already has a filesystem, so data survives a
# stop→start. If DEVICE is empty or absent (e.g. no volume attached / a
# container), it logs and skips the mount but still creates the mountpoint dir.
mount_volume() {
	dev="$1"; mp="$2"
	mkdir -p "$mp"
	if [ -z "$dev" ] || [ ! -e "$dev" ]; then
		log_info "no block device at '${dev:-<unset>}' — skipping mount of $mp"
		return 0
	fi
	# Create a filesystem only when the volume has none (protects existing data).
	if blkid "$dev" >/dev/null 2>&1; then
		log_info "$dev already has a filesystem — not reformatting"
	else
		log_info "formatting $dev as ext4 (volume is empty)"
		mkfs.ext4 -F "$dev"
	fi
	# Mount now if not already mounted.
	if mountpoint -q "$mp"; then
		log_info "$mp already mounted"
	else
		log_info "mounting $dev at $mp"
		mount -o defaults,nofail,discard,noatime "$dev" "$mp"
	fi
	# Persist across reboots — DO recommends the by-id device path, not a UUID.
	fstab_line="$dev $mp ext4 defaults,nofail,discard,noatime 0 2"
	if grep -qF "$fstab_line" "$FSTAB_FILE" 2>/dev/null; then
		log_debug "fstab entry for $mp already present"
	else
		log_info "recording $mp in $FSTAB_FILE"
		printf '%s\n' "$fstab_line" >>"$FSTAB_FILE"
	fi
}

# --- 1. apt: python + venv + pip --------------------------------------------
log_info "installing OS packages (python3, venv, pip)"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip

# --- 2. data volume ---------------------------------------------------------
mount_volume "$DATA_DEVICE" "$DATA_MOUNT"

# --- 3. log dir on the data volume ------------------------------------------
log_info "creating log dir $LOG_DIR"
mkdir -p "$LOG_DIR"

# --- 4. venv + app deps -----------------------------------------------------
if [ -d "$VENV_DIR" ]; then
	log_info "venv already exists at $VENV_DIR"
else
	log_info "creating venv at $VENV_DIR"
	mkdir -p "$APP_DIR"
	python3 -m venv "$VENV_DIR"
fi
if [ -f "$REQUIREMENTS_FILE" ]; then
	log_info "installing app dependencies from $REQUIREMENTS_FILE"
	"$VENV_DIR/bin/python" -m pip install -r "$REQUIREMENTS_FILE"
else
	log_info "no requirements file at $REQUIREMENTS_FILE — skipping pip install"
fi

log_info "CPU droplet provisioning complete"
