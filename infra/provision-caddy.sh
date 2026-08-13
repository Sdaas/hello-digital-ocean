#!/usr/bin/env bash
#
# provision-caddy.sh — front the app with Caddy for trusted HTTPS (F14, #31).
#
# Runs as root ON THE APP (CPU) DROPLET, invoked over SSH by the `digital-ocean`
# CLI during `start`, AFTER the app is deployed and healthy on loopback. Droplets
# are ephemeral (ADR-0001), so this reinstalls every time; it is IDEMPOTENT.
#
# Why: a public `http://<ip>:<port>` origin is not a "secure context", so browsers
# block `getUserMedia` (mic). Caddy terminates HTTPS on :443 (and redirects :80),
# reverse-proxying to the app on 127.0.0.1:$APP_PORT, using a <dashed-ip>.sslip.io
# hostname so Let's Encrypt can issue a TRUSTED cert with no owned domain. See
# docs/tls-setup-guide.md for how sslip.io + Caddy + Let's Encrypt combine.
#
# What it does:
#   1. Install Caddy from its official apt repo (idempotent — skips if present).
#   2. Write $CADDYFILE: the sslip.io site reverse-proxying to the loopback app,
#      with an optional global block (email / acme_ca staging override).
#   3. Enable + (re)start the caddy service so it loads the new config and
#      obtains/renews the Let's Encrypt cert over ACME. (Skipped when NO_SERVICE=1,
#      e.g. a base container with no init — used by the integration test.)
#
#   Env var        Default                                     Meaning
#   TLS_HOSTNAME   (required)                                  <dashed-ip>.sslip.io site address
#   APP_PORT       5000                                        loopback app port to proxy to
#   ACME_CA        (unset)                                     ACME directory URL; set → LE staging
#   ACME_EMAIL     (unset)                                     ACME registration email (optional)
#   CADDYFILE      /etc/caddy/Caddyfile                        Caddy config path (overridable for tests)
#   KEYRING_FILE   /usr/share/keyrings/caddy-stable-archive-keyring.gpg   apt repo keyring
#   APT_LIST_FILE  /etc/apt/sources.list.d/caddy-stable.list   apt source list
#   NO_SERVICE     (unset)                                     set → skip systemctl (no init present)

set -euo pipefail

# --- config (env override > default) ----------------------------------------
TLS_HOSTNAME="${TLS_HOSTNAME:-}"
APP_PORT="${APP_PORT:-5000}"
ACME_CA="${ACME_CA:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
KEYRING_FILE="${KEYRING_FILE:-/usr/share/keyrings/caddy-stable-archive-keyring.gpg}"
APT_LIST_FILE="${APT_LIST_FILE:-/etc/apt/sources.list.d/caddy-stable.list}"
NO_SERVICE="${NO_SERVICE:-}"
CADDY_GPG_URL="${CADDY_GPG_URL:-https://dl.cloudsmith.io/public/caddy/stable/gpg.key}"
CADDY_LIST_URL="${CADDY_LIST_URL:-https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt}"

# --- logging (leveled, to stderr; matches the digital-ocean CLI idiom) -------
LOG_LEVEL=INFO
log() {
	level="$1"; shift
	if [ "$level" = DEBUG ] && [ "$LOG_LEVEL" != DEBUG ]; then return 0; fi
	printf '%s %s provision-caddy: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}
log_debug() { log DEBUG "$@"; }
log_info()  { log INFO  "$@"; }
log_error() { log ERROR "$@"; }

usage() {
	cat <<EOF
Usage: provision-caddy.sh [--help] [--verbose]

Front the app with Caddy for trusted HTTPS (F14, #31): install Caddy, write a
Caddyfile whose site \$TLS_HOSTNAME (a <dashed-ip>.sslip.io name) reverse-proxies
to the loopback app on 127.0.0.1:\$APP_PORT, then enable + restart the caddy
service (which obtains a Let's Encrypt cert over ACME). Idempotent; run as root
over SSH by \`digital-ocean start\`. Configured by environment variables — see
the header of this script.
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

# --- 0. validate contract ---------------------------------------------------
if [ -z "$TLS_HOSTNAME" ]; then
	log_error "TLS_HOSTNAME is required (the <dashed-ip>.sslip.io site address)"
	exit 2
fi

# --- 1. install Caddy from its official apt repo ----------------------------
# Idempotent: skip the whole repo dance if the binary is already present.
if command -v caddy >/dev/null 2>&1; then
	log_info "caddy already installed — skipping apt repo setup"
else
	log_info "installing Caddy from its official apt repo"
	export DEBIAN_FRONTEND=noninteractive
	apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
	# Fetch the repo signing key and register the apt source (DO's/Caddy's documented
	# install path). The keyring + list paths are overridable so tests can redirect them.
	curl -1sLf "$CADDY_GPG_URL" | gpg --dearmor -o "$KEYRING_FILE"
	curl -1sLf "$CADDY_LIST_URL" | tee "$APT_LIST_FILE" >/dev/null
	apt-get update
	apt-get install -y caddy
fi

# --- 2. write the Caddyfile -------------------------------------------------
# An optional global block carries the ACME email and — only for staging — an
# acme_ca override; production Let's Encrypt is Caddy's default (no override).
log_info "writing Caddy config to $CADDYFILE (site $TLS_HOSTNAME → 127.0.0.1:$APP_PORT)"
mkdir -p "$(dirname "$CADDYFILE")"
{
	if [ -n "$ACME_EMAIL" ] || [ -n "$ACME_CA" ]; then
		printf '{\n'
		[ -n "$ACME_EMAIL" ] && printf '\temail %s\n' "$ACME_EMAIL"
		# ACME_CA set → use the Let's Encrypt STAGING directory (avoids burning the
		# production rate-limit while iterating). Unset → production LE (the default).
		[ -n "$ACME_CA" ] && printf '\tacme_ca %s\n' "$ACME_CA"
		printf '}\n\n'
	fi
	# Caddy auto-provisions HTTPS + redirects :80→:443 for a hostname site address.
	printf '%s {\n' "$TLS_HOSTNAME"
	printf '\treverse_proxy 127.0.0.1:%s\n' "$APP_PORT"
	printf '}\n'
} >"$CADDYFILE"

# Validate the config if the binary is available (real flow / integration test);
# in the hermetic lane caddy isn't actually installed, so this is skipped.
if command -v caddy >/dev/null 2>&1; then
	log_info "validating $CADDYFILE"
	caddy validate --config "$CADDYFILE" --adapter caddyfile
fi

# --- 3. enable + (re)start the service --------------------------------------
if [ -n "$NO_SERVICE" ]; then
	log_info "NO_SERVICE set — skipping systemctl (no init present)"
else
	log_info "enabling + restarting the caddy service"
	systemctl enable caddy
	systemctl restart caddy
fi

log_info "Caddy HTTPS provisioning complete — https://$TLS_HOSTNAME"
