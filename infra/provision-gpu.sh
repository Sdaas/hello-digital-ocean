#!/usr/bin/env bash
#
# provision-gpu.sh — provision a fresh Ubuntu GPU droplet to serve Ollama (F5).
#
# Runs as root ON THE DROPLET, invoked over SSH by the `digital-ocean` CLI (F7).
# Idempotent: re-running skips work already done.
#
# What it does:
#   1. ASSERT the NVIDIA driver is present and working (`nvidia-smi`). DO's
#      AI/ML-ready image ships the driver, but it can be finalized by cloud-init
#      at first boot, so this POLLS up to $NVIDIA_WAIT_SECS before giving up. It
#      does NOT install drivers — that is the image's job (F5 scope boundary).
#   2. Attach the models Block Storage volume at $MODELS_MOUNT (/mnt/models):
#      format-if-empty (never reformat — models persist across stop→start,
#      ADR-0003), mount, and record it in /etc/fstab (DO by-id device path).
#   3. Install Ollama (skips if already installed).
#   4. Point Ollama at the models volume and bind it on the VPC via a systemd
#      drop-in ($OLLAMA_MODELS=$MODELS_MOUNT, $OLLAMA_HOST), chown the volume to
#      the ollama user, then reload + (re)start the service.
#
# It does NOT pull any model (that is C8/F7) or configure a firewall (F6/F7).
# Configuration is via environment variables; F7 exports them over SSH.
#
#   Env var            Default                              Meaning
#   MODELS_MOUNT       /mnt/models                          models volume mountpoint
#   MODELS_VOLUME_NAME (unset)                              DO volume name → device
#   MODELS_DEVICE      by-id path from MODELS_VOLUME_NAME   block device to mount
#   NVIDIA_WAIT_SECS   120                                  poll budget for nvidia-smi
#   OLLAMA_HOST        0.0.0.0:11434                        Ollama bind (VPC-reachable)
#   OLLAMA_INSTALL_URL https://ollama.com/install.sh        installer to curl | sh
#   FSTAB_FILE         /etc/fstab                           (overridable for tests)
#   SYSTEMD_DIR        /etc/systemd/system                  (overridable for tests)

set -euo pipefail

# --- config (env override > default) ----------------------------------------
MODELS_MOUNT="${MODELS_MOUNT:-/mnt/models}"
MODELS_VOLUME_NAME="${MODELS_VOLUME_NAME:-}"
MODELS_DEVICE="${MODELS_DEVICE:-${MODELS_VOLUME_NAME:+/dev/disk/by-id/scsi-0DO_Volume_$MODELS_VOLUME_NAME}}"
NVIDIA_WAIT_SECS="${NVIDIA_WAIT_SECS:-120}"
OLLAMA_HOST="${OLLAMA_HOST:-0.0.0.0:11434}"
OLLAMA_INSTALL_URL="${OLLAMA_INSTALL_URL:-https://ollama.com/install.sh}"
FSTAB_FILE="${FSTAB_FILE:-/etc/fstab}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

# --- logging (leveled, to stderr; matches the digital-ocean CLI idiom) -------
LOG_LEVEL=INFO
log() {
	level="$1"; shift
	if [ "$level" = DEBUG ] && [ "$LOG_LEVEL" != DEBUG ]; then return 0; fi
	printf '%s %s provision-gpu: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}
log_debug() { log DEBUG "$@"; }
log_info()  { log INFO  "$@"; }
log_error() { log ERROR "$@"; }

usage() {
	cat <<EOF
Usage: provision-gpu.sh [--help] [--verbose]

Provision a fresh Ubuntu GPU droplet to serve Ollama: assert the NVIDIA driver,
mount the models volume at \$MODELS_MOUNT (${MODELS_MOUNT}), install Ollama, and
point it at the volume + VPC via a systemd drop-in. Idempotent; run as root over
SSH (F7). Configured by environment variables — see the header of this script.
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
# Identical intent to provision-cpu.sh's copy; deliberately duplicated so each
# script is self-contained and F7 can SCP either one on its own.
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

# assert_nvidia — poll nvidia-smi up to NVIDIA_WAIT_SECS; fail if never healthy.
assert_nvidia() {
	waited=0
	while true; do
		if nvidia-smi >/dev/null 2>&1; then
			log_info "NVIDIA driver present and responding"
			return 0
		fi
		if [ "$waited" -ge "$NVIDIA_WAIT_SECS" ]; then
			log_error "nvidia-smi not available/healthy after ${NVIDIA_WAIT_SECS}s — this must be a GPU droplet with the NVIDIA driver (DO AI/ML image); not installing drivers here"
			return 1
		fi
		log_debug "nvidia-smi not ready yet (waited ${waited}s) — driver may still be finalizing via cloud-init"
		sleep 1
		waited=$((waited + 1))
	done
}

# --- 1. assert the GPU driver -----------------------------------------------
assert_nvidia || exit 1

# --- 2. models volume -------------------------------------------------------
mount_volume "$MODELS_DEVICE" "$MODELS_MOUNT"

# --- 3. install Ollama ------------------------------------------------------
if command -v ollama >/dev/null 2>&1; then
	log_info "Ollama already installed — skipping install"
else
	log_info "installing Ollama from $OLLAMA_INSTALL_URL"
	curl -fsSL "$OLLAMA_INSTALL_URL" | sh
fi

# --- 4. point Ollama at the models volume + VPC, then (re)start -------------
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

log_info "GPU droplet provisioning complete"
