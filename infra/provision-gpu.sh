#!/usr/bin/env bash
#
# provision-gpu.sh — provision a fresh Ubuntu GPU droplet to serve Ollama (F5).
#
# Runs as root ON THE DROPLET, invoked over SSH by the `digital-ocean` CLI (F7).
# Idempotent: re-running skips work already done.
#
# What it does:
#   1. INSTALL the NVIDIA driver, then ASSERT it works (`nvidia-smi`). We boot a
#      plain Ubuntu image (there is no public RTX-6000-Ada base image), so the
#      driver is installed here via `ubuntu-drivers` (#17, ADR-0002). The step is
#      idempotent — it is skipped when nvidia-smi is already healthy — and can be
#      disabled with $NVIDIA_INSTALL=0 (used by the GPU-less container test). The
#      assertion then POLLS up to $NVIDIA_WAIT_SECS as the post-install gate.
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
#   NVIDIA_INSTALL     1                                    install driver (0 to skip)
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
NVIDIA_INSTALL="${NVIDIA_INSTALL:-1}"
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

# install_nvidia_driver — install the NVIDIA driver on a plain Ubuntu image.
# Idempotent: no-op when nvidia-smi is already healthy. Skipped when
# NVIDIA_INSTALL=0 (GPU-less container test / caller supplies its own driver).
# Ollama bundles its own CUDA userspace, so only the kernel driver is installed.
install_nvidia_driver() {
	if [ "$NVIDIA_INSTALL" = 0 ]; then
		log_info "NVIDIA_INSTALL=0 — skipping driver install (assert only)"
		return 0
	fi
	if nvidia-smi >/dev/null 2>&1; then
		log_info "NVIDIA driver already healthy — skipping install"
		return 0
	fi
	log_info "installing the NVIDIA driver via ubuntu-drivers (plain Ubuntu image)"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install -y ubuntu-drivers-common
	# `ubuntu-drivers install` auto-selects the right driver for the card.
	ubuntu-drivers install
	# Load the module now so the assert below can pass without a reboot; harmless
	# if it is already loaded. A reboot is only needed if this cannot bind.
	modprobe nvidia 2>/dev/null || log_info "modprobe nvidia not yet loadable — the assert poll will confirm"
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
			log_error "nvidia-smi not available/healthy after ${NVIDIA_WAIT_SECS}s — driver install did not bind; this must be a GPU droplet and may need a reboot for the kernel module to load"
			return 1
		fi
		log_debug "nvidia-smi not ready yet (waited ${waited}s) — driver may still be finalizing via cloud-init"
		sleep 1
		waited=$((waited + 1))
	done
}

# --- 1. install + assert the GPU driver -------------------------------------
install_nvidia_driver
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
