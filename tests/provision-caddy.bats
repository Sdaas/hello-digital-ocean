#!/usr/bin/env bats
#
# Fast/hermetic tests for infra/provision-caddy.sh (F14, #31). This script runs as
# root on the app (CPU) droplet, invoked over SSH by `start`, to front the app with
# Caddy so the browser gets a trusted-HTTPS secure origin (mic works) via a
# <dashed-ip>.sslip.io hostname + Let's Encrypt. Every Ubuntu-only boundary —
# apt-get, the Caddy apt repo (curl|gpg|tee), and systemctl — is PATH-shimmed, and
# every path (Caddyfile, the keyring + apt list) is redirected into
# $BATS_TEST_TMPDIR. Nothing real runs here. The un-mocked counterpart runs the
# script in a real ubuntu container (tests/integration/provision-caddy.bats: real
# apt install of Caddy + `caddy validate`); the real Let's Encrypt ACME + sslip.io
# DNS + browser-trust boundary is only provable live (the billable VERIFY).
#
# NOTE: bats silently ignores a mid-test `[[ ]]` that returns false, so substring
# checks use `grep -q` (a simple command bats DOES catch).

CADDY=infra/provision-caddy.sh

setup() {
	SHIM="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$SHIM"

	# Redirect every filesystem target into the throwaway tmpdir.
	export CADDYFILE="$BATS_TEST_TMPDIR/Caddyfile"
	export KEYRING_FILE="$BATS_TEST_TMPDIR/caddy-keyring.gpg"
	export APT_LIST_FILE="$BATS_TEST_TMPDIR/caddy.list"

	# The app facts the CLI passes over SSH.
	export TLS_HOSTNAME="203-0-113-10.sslip.io"
	export APP_PORT=5000

	# Logs the shims append to, so tests can assert what got invoked.
	export APTLOG="$BATS_TEST_TMPDIR/apt.log"
	export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"

	_shim_apt
	# curl: emit a token to stdout so the downstream gpg|tee pipe has input.
	_shim_present curl "echo caddy-repo-bytes"
	# gpg --dearmor -o FILE : create the keyring FILE (drain stdin).
	_shim_present gpg  'out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { out="$2"; shift; }; shift; done; cat >/dev/null; [ -n "$out" ] && : >"$out"'
	# tee FILE : write stdin to FILE (faithful enough for the assertion).
	_shim_present tee  'for a in "$@"; do case "$a" in -*) ;; *) cat >"$a"; exit 0;; esac; done; cat >/dev/null'
	_shim_systemctl

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

_shim_systemctl() {
	cat >"$SHIM/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$SYSTEMCTL_LOG"
exit 0
EOF
	chmod +x "$SHIM/systemctl"
}

# --- install ----------------------------------------------------------------

@test "installs Caddy from its apt repo (keyring + apt list + apt install caddy)" {
	run bash "$CADDY"
	echo "$output"
	[ "$status" -eq 0 ]
	# Caddy apt repo wired up and the package installed.
	grep -q "install -y caddy" "$APTLOG"
	# The repo keyring + source list were written into the (redirected) targets.
	[ -f "$KEYRING_FILE" ]
	[ -f "$APT_LIST_FILE" ]
}

@test "starts + enables the caddy service" {
	run bash "$CADDY"
	[ "$status" -eq 0 ]
	grep -qE "systemctl (enable|restart|start).*caddy" "$SYSTEMCTL_LOG"
}

# --- Caddyfile --------------------------------------------------------------

@test "writes a Caddyfile with the sslip.io site reverse-proxying to the loopback app" {
	run bash "$CADDY"
	[ "$status" -eq 0 ]
	[ -f "$CADDYFILE" ]
	# Site address is the dashed-ip sslip.io hostname (so Caddy gets a trusted cert).
	grep -q "203-0-113-10.sslip.io" "$CADDYFILE"
	# Reverse-proxies to the app on loopback (the app no longer binds the public net).
	grep -q "reverse_proxy 127.0.0.1:5000" "$CADDYFILE"
}

@test "production Let's Encrypt by default: no acme_ca staging override in the Caddyfile" {
	run bash "$CADDY"
	[ "$status" -eq 0 ]
	# Without ACME_CA, Caddy uses production LE — no explicit acme_ca line.
	run grep -q "acme_ca" "$CADDYFILE"
	[ "$status" -ne 0 ]
}

@test "ACME_CA set (staging) writes the acme_ca override into the Caddyfile global block" {
	ACME_CA="https://acme-staging-v02.api.letsencrypt.org/directory" run bash "$CADDY"
	[ "$status" -eq 0 ]
	grep -q "acme_ca https://acme-staging-v02.api.letsencrypt.org/directory" "$CADDYFILE"
}

@test "ACME_EMAIL set writes the email into the Caddyfile global block" {
	ACME_EMAIL="ops@example.com" run bash "$CADDY"
	[ "$status" -eq 0 ]
	grep -q "email ops@example.com" "$CADDYFILE"
}

# --- contract / robustness --------------------------------------------------

@test "fails fast when TLS_HOSTNAME is missing" {
	unset TLS_HOSTNAME
	run bash "$CADDY"
	[ "$status" -ne 0 ]
	echo "$output" | grep -qi "TLS_HOSTNAME"
}

@test "idempotent: a second run also succeeds and leaves a valid Caddyfile" {
	run bash "$CADDY"
	[ "$status" -eq 0 ]
	run bash "$CADDY"
	[ "$status" -eq 0 ]
	grep -q "reverse_proxy 127.0.0.1:5000" "$CADDYFILE"
}

@test "APP_PORT override is honored in the reverse_proxy upstream" {
	APP_PORT=8080 run bash "$CADDY"
	[ "$status" -eq 0 ]
	grep -q "reverse_proxy 127.0.0.1:8080" "$CADDYFILE"
}

@test "--help prints usage and exits 0" {
	run bash "$CADDY" --help
	[ "$status" -eq 0 ]
	echo "$output" | grep -qi "caddy"
}
