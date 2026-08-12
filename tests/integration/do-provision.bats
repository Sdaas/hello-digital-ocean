#!/usr/bin/env bats
#
# Opt-in, UN-MOCKED real-boundary test for `digital-ocean provision` (F6). It
# drives the SAME helper functions the CLI uses (loaded via the DO_SOURCE_ONLY
# guard) against LIVE DigitalOcean: it really creates a throwaway VPC + a 1 GiB
# volume, proves adopt-by-name is idempotent (a second ensure returns the same
# ID and creates nothing), then destroys both. This is the required real-boundary
# counterpart to the stubbed doctl in the fast lane (tests/do-provision.bats).
#
# It self-skips unless doctl is installed AND authenticated AND the operator
# explicitly opts in with DO_REAL_PROVISION=1 — so `./test.sh --integration`
# never bills by accident. A 1 GiB volume + VPC that live for seconds cost about
# a cent. The ATTACH positive path and the (expensive) real DROPLET create are
# deferred to F7's `start`, mirroring F5's deferred volume-mount VERIFY.
#
# Cleanup is trap-based inside the driver, so resources are removed even if an
# assertion fails mid-run.

setup() {
	command -v doctl >/dev/null 2>&1 || skip "doctl not installed"
	doctl account get >/dev/null 2>&1 || skip "doctl not authenticated (run: doctl auth init)"
	[ "${DO_REAL_PROVISION:-}" = 1 ] ||
		skip "set DO_REAL_PROVISION=1 to run the billable real-provision test (~1¢)"
}

@test "real doctl: ensure_vpc + ensure_volume create, adopt (idempotent), destroy" {
	drive="$BATS_TEST_TMPDIR/drive.sh"
	cat >"$drive" <<'EOF'
set -eu
export DO_SOURCE_ONLY=1
. ./bin/digital-ocean          # load helpers without running main

DO_REGION="${DO_REGION:-ams3}"
suffix="itest-$$-${RANDOM}"
vpc="hello-do-${suffix}-vpc"
vol="hello-do-${suffix}-vol"

cleanup() {
	vid="$(doctl compute volume list --format Name,ID --no-header 2>/dev/null | awk -v n="$vol" '$1==n{print $2}')"
	[ -n "$vid" ] && doctl compute volume delete "$vid" --force >/dev/null 2>&1 || true
	pid="$(doctl vpcs list --format Name,ID --no-header 2>/dev/null | awk -v n="$vpc" '$1==n{print $2}')"
	[ -n "$pid" ] && doctl vpcs delete "$pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# VPC: create, then adopt (same ID, no second create).
id1="$(ensure_vpc "$vpc")"
[ -n "$id1" ] || { echo "FAIL: empty vpc id"; exit 1; }
id2="$(ensure_vpc "$vpc")"
[ "$id1" = "$id2" ] || { echo "FAIL: vpc not adopted ($id1 != $id2)"; exit 1; }

# Volume: create (1 GiB, ext4), then adopt.
vid1="$(ensure_volume "$vol" 1)"
[ -n "$vid1" ] || { echo "FAIL: empty volume id"; exit 1; }
vid2="$(ensure_volume "$vol" 1)"
[ "$vid1" = "$vid2" ] || { echo "FAIL: volume not adopted ($vid1 != $vid2)"; exit 1; }

echo "OK vpc=$id1 vol=$vid1"
EOF
	run bash "$drive"
	echo "$output"
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "OK vpc="
}

# Un-mocked counterpart for the F13/#30 `doctl projects` boundary (create/list/
# adopt/resources assign). Projects are FREE; the only billable atom is a 1 GiB
# volume that lives for seconds (~1¢), reused here as the assignable resource.
# Same opt-in guard as above.
@test "real doctl: ensure_project creates, adopts (idempotent), assigns a volume, cleans up" {
	drive="$BATS_TEST_TMPDIR/drive.sh"
	cat >"$drive" <<'EOF'
set -eu
export DO_SOURCE_ONLY=1
. ./bin/digital-ocean          # load helpers without running main

DO_REGION="${DO_REGION:-ams3}"
DEPLOY_ENV=prod                # drives _do_project_environment → Production
suffix="itest-$$-${RANDOM}"
proj="hello-do-${suffix}-proj"
vol="hello-do-${suffix}-vol"

cleanup() {
	vid="$(doctl compute volume list --format Name,ID --no-header 2>/dev/null | awk -v n="$vol" '$1==n{print $2}')"
	[ -n "$vid" ] && doctl compute volume delete "$vid" --force >/dev/null 2>&1 || true
	pid="$(doctl projects list --format ID,Name --no-header 2>/dev/null | awk -v n="$proj" '$2==n{print $1}')"
	[ -n "$pid" ] && doctl projects delete "$pid" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Project: create, then adopt (same ID, no second create).
id1="$(ensure_project "$proj")"
[ -n "$id1" ] || { echo "FAIL: empty project id"; exit 1; }
id2="$(ensure_project "$proj")"
[ "$id1" = "$id2" ] || { echo "FAIL: project not adopted ($id1 != $id2)"; exit 1; }

# Assign: a real volume by URN, then confirm it shows under the project.
vid="$(ensure_volume "$vol" 1)"
doctl projects resources assign "$id1" --resource "do:volume:$vid" >/dev/null
doctl projects resources list "$id1" --format URN --no-header 2>/dev/null | grep -q "do:volume:$vid" \
	|| { echo "FAIL: volume not listed under project"; exit 1; }

echo "OK project=$id1 vol=$vid"
EOF
	run bash "$drive"
	echo "$output"
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "OK project="
}
