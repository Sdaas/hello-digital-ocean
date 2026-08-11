#!/usr/bin/env bats
#
# Opt-in, UN-MOCKED real-boundary test for `digital-ocean start` (F7). The fast
# lane (tests/do-start.bats) stubs doctl/ssh/scp/rsync, so this file exercises the
# one boundary a stub can't prove but that is *cheap* to hit for real: the doctl
# cloud-FIREWALL verbs. It drives the SAME helper the CLI uses (loaded via the
# DO_SOURCE_ONLY guard) against LIVE DigitalOcean — really creating a firewall,
# proving adopt-by-name is idempotent, then destroying it. Firewalls are free, so
# this bills nothing.
#
# The remaining F7 boundaries — ssh/scp/rsync to the droplets, the F5 provision
# scripts, `ollama pull`, and the app /health — are exercised by the BILLABLE
# live VERIFY (a real `digital-ocean start` → chat → `stop`), the un-mocked
# evidence F5/F6 deferred to F7. There is no free stand-in for a GPU droplet.
#
# Self-skips unless doctl is installed AND authenticated AND the operator opts in
# with DO_REAL_START=1, so `./test.sh --integration` never touches live DO by
# accident. Cleanup is trap-based, so the firewall is removed even on failure.

setup() {
	command -v doctl >/dev/null 2>&1 || skip "doctl not installed"
	doctl account get >/dev/null 2>&1 || skip "doctl not authenticated (run: doctl auth init)"
	[ "${DO_REAL_START:-}" = 1 ] ||
		skip "set DO_REAL_START=1 to run the free real-firewall test (no billable resources)"
}

@test "real doctl: ensure_firewall creates, adopts (idempotent), destroys" {
	drive="$BATS_TEST_TMPDIR/drive.sh"
	cat >"$drive" <<'EOF'
set -eu
export DO_SOURCE_ONLY=1
. ./bin/digital-ocean          # load helpers without running main

fw="hello-do-itest-$$-${RANDOM}-fw"

cleanup() {
	fid="$(doctl compute firewall list --format Name,ID --no-header 2>/dev/null | awk -v n="$fw" '$1==n{print $2}')"
	[ -n "$fid" ] && doctl compute firewall delete "$fid" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Create, then adopt (same ID, no second create).
id1="$(ensure_firewall "$fw" "protocol:tcp,ports:5000,address:0.0.0.0/0,address:::/0")"
[ -n "$id1" ] || { echo "FAIL: empty firewall id"; exit 1; }
id2="$(ensure_firewall "$fw" "protocol:tcp,ports:5000,address:0.0.0.0/0,address:::/0")"
[ "$id1" = "$id2" ] || { echo "FAIL: firewall not adopted ($id1 != $id2)"; exit 1; }

echo "OK fw=$id1"
EOF
	run bash "$drive"
	echo "$output"
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "OK fw="
}
