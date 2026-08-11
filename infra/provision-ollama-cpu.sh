#!/usr/bin/env bash
#
# provision-ollama-cpu.sh — provision a fresh Ubuntu CPU droplet to serve Ollama
# on CPU (#18). This is the cheap, GPU-free backend: same shape as
# provision-gpu.sh but WITHOUT the NVIDIA driver assertion (a plain Ubuntu box).
#
# Runs as root ON THE DROPLET, invoked over SSH by the `digital-ocean` CLI
# (`start`). Idempotent: re-running skips work already done.
#
# What it does:
#   1. Attach the models Block Storage volume at $MODELS_MOUNT (/mnt/models):
#      format-if-empty (never reformat — models persist across stop→start,
#      ADR-0003), mount, and record it in /etc/fstab (DO by-id device path).
#   2. Install Ollama (skips if already installed).
#   3. Point Ollama at the models volume and bind it to $OLLAMA_HOST via a systemd
#      drop-in. `start` sets OLLAMA_HOST to the node's PRIVATE VPC IP (#19), so
#      :11434 is off the public net with no firewall. chown the volume to the
#      ollama user, then reload + (re)start the service.
#
# It does NOT pull any model (that is `start`) or configure a firewall. Config is
# via environment variables; `start` exports them over SSH.
#
#   Env var            Default                              Meaning
#   MODELS_MOUNT       /mnt/models                          models volume mountpoint
#   MODELS_VOLUME_NAME (unset)                              DO volume name → device
#   MODELS_DEVICE      by-id path from MODELS_VOLUME_NAME   block device to mount
#   OLLAMA_HOST        0.0.0.0:11434                        Ollama bind (start sets the private IP)
#   OLLAMA_INSTALL_URL https://ollama.com/install.sh        installer to curl | sh
#   FSTAB_FILE         /etc/fstab                           (overridable for tests)
#   SYSTEMD_DIR        /etc/systemd/system                  (overridable for tests)

set -euo pipefail

# --- config (env override > default) ----------------------------------------
MODELS_MOUNT="${MODELS_MOUNT:-/mnt/models}"
MODELS_VOLUME_NAME="${MODELS_VOLUME_NAME:-}"
MODELS_DEVICE="${MODELS_DEVICE:-${MODELS_VOLUME_NAME:+/dev/disk/by-id/scsi-0DO_Volume_$MODELS_VOLUME_NAME}}"
OLLAMA_HOST="${OLLAMA_HOST:-0.0.0.0:11434}"
OLLAMA_INSTALL_URL="${OLLAMA_INSTALL_URL:-https://ollama.com/install.sh}"
FSTAB_FILE="${FSTAB_FILE:-/etc/fstab}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

# --- logging (leveled, to stderr; matches the digital-ocean CLI idiom) -------
LOG_LEVEL=INFO
log() {
	level="$1"; shift
	if [ "$level" = DEBUG ] && [ "$LOG_LEVEL" != DEBUG ]; then return 0; fi
	printf '%s %s provision-ollama-cpu: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}
log_debug() { log DEBUG "$@"; }
log_info()  { log INFO  "$@"; }
log_error() { log ERROR "$@"; }

usage() {
	cat <<EOF
Usage: provision-ollama-cpu.sh [--help] [--verbose]

Provision a fresh Ubuntu CPU droplet to serve Ollama on CPU (the cheap, GPU-free
backend): mount the models volume at \$MODELS_MOUNT (${MODELS_MOUNT}), install
Ollama, and point it at the volume + bind \$OLLAMA_HOST (${OLLAMA_HOST}) via a
systemd drop-in. Idempotent; run as root over SSH by \`start\`. Configured by
environment variables — see the header of this script.
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

# mount_volume DEVICE MOUNTPOINT — format-if-empty, mount, persist in fstab.
# Identical intent to provision-cpu.sh / provision-gpu.sh's copy; deliberately
# duplicated so each script is self-contained and `start` can SCP any one alone.
mount_volume() {
	dev="$1"; mp="$2"
	mkdir -p "$mp"
	if [ -z "$dev" ] || [ ! -e "$dev" ]; then
		log_info "no block device at '${dev:-<unset>}' — skipping mount of $mp"
		return 0
	fi
	if blkid "$dev" >/dev/null 2>&1; then
		log_info "$dev already has a filesystem — not reformatting"
	else
		log_info "formatting $dev as ext4 (volume is empty)"
		mkfs.ext4 -F "$dev"
	fi
	if mountpoint -q "$mp"; then
		log_info "$mp already mounted"
	else
		log_info "mounting $dev at $mp"
		mount -o defaults,nofail,discard,noatime "$dev" "$mp"
	fi
	fstab_line="$dev $mp ext4 defaults,nofail,discard,noatime 0 2"
	if grep -qF "$fstab_line" "$FSTAB_FILE" 2>/dev/null; then
		log_debug "fstab entry for $mp already present"
	else
		log_info "recording $mp in $FSTAB_FILE"
		printf '%s\n' "$fstab_line" >>"$FSTAB_FILE"
	fi
}

# --- 1. models volume -------------------------------------------------------
mount_volume "$MODELS_DEVICE" "$MODELS_MOUNT"

# --- 2. install Ollama ------------------------------------------------------
if command -v ollama >/dev/null 2>&1; then
	log_info "Ollama already installed — skipping install"
else
	log_info "installing Ollama from $OLLAMA_INSTALL_URL"
	curl -fsSL "$OLLAMA_INSTALL_URL" | sh
fi

# --- 3. point Ollama at the models volume + bind host, then (re)start -------
override_dir="$SYSTEMD_DIR/ollama.service.d"
override="$override_dir/override.conf"
log_info "writing Ollama systemd drop-in $override"
mkdir -p "$override_dir"
cat >"$override" <<EOF
[Service]
Environment="OLLAMA_MODELS=$MODELS_MOUNT"
Environment="OLLAMA_HOST=$OLLAMA_HOST"
EOF

log_info "giving the ollama user ownership of $MODELS_MOUNT"
chown -R ollama:ollama "$MODELS_MOUNT"

log_info "reloading systemd and (re)starting the ollama service"
systemctl daemon-reload
systemctl enable --now ollama
systemctl restart ollama

log_info "CPU Ollama node provisioning complete"
