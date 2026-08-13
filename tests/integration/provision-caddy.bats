#!/usr/bin/env bats
#
# Integration (un-mocked) test for infra/provision-caddy.sh (F14, #31). Runs the
# script in a REAL ubuntu:22.04 Docker container — the closest thing to a fresh
# droplet without paid DO infra. Opt-in (`./test.sh --integration`); self-skips
# when Docker is unavailable, so PR CI stays green without a container runtime.
#
# What it really exercises (the boundaries the fast lane only shimmed):
#   - the Caddy apt repo setup + real `apt-get install caddy`,
#   - a real Caddyfile written for the sslip.io site, then `caddy validate` on it.
#
# Deferred to the billable live VERIFY (a real public droplet): the Let's Encrypt
# ACME issuance, sslip.io DNS resolution, and browser cert-trust — none of which a
# container can provide (no public IP, no inbound :80/:443 from LE). See
# design/overview.md. systemctl is not exercised here (no init in a base container);
# the fast lane asserts the enable/restart calls, and the live VERIFY proves the
# service actually serves HTTPS.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
IMAGE=ubuntu:22.04

setup() {
	if ! command -v docker >/dev/null 2>&1; then
		skip "docker not installed"
	fi
	if ! docker info >/dev/null 2>&1; then
		skip "docker daemon not running"
	fi
}

@test "integration: provision-caddy.sh really installs Caddy and validates the generated Caddyfile" {
	# NO_SERVICE=1 tells the script to skip systemctl (a base container has no init).
	run docker run --rm -v "$REPO:/repo:ro" \
		-e TLS_HOSTNAME=203-0-113-10.sslip.io \
		-e APP_PORT=5000 \
		-e CADDYFILE=/tmp/Caddyfile \
		-e NO_SERVICE=1 \
		"$IMAGE" \
		bash -c 'apt-get update >/dev/null && bash /repo/infra/provision-caddy.sh && caddy validate --config /tmp/Caddyfile --adapter caddyfile'
	echo "$output"
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "203-0-113-10.sslip.io"
}
