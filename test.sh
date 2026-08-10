#!/usr/bin/env bash
#
# test.sh — single test entrypoint for hello-digital-ocean.
# Runs shellcheck (if available) then the bats suite. Non-zero on any failure.
# This is what the pre-push hook and CI both call.
#
#   ./test.sh                 fast/hermetic lane (bats tests/)
#   ./test.sh --integration   also runs the integration lane (tests/integration/)
#
# The integration lane holds real-boundary tests (a live service, secrets, real
# hardware). Its home is LOCAL — the pre-push hook runs it — because a stock CI
# runner can't provide those boundaries. Integration tests should self-skip
# (bats `skip`) when their boundary is absent, so this lane stays non-blocking.
# PR CI runs the fast lane only.
#
# Dev dependency: bats-core (https://github.com/bats-core/bats-core).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1

# --- args -------------------------------------------------------------------
INTEGRATION=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	--integration) INTEGRATION=1 ;;
	--help | -h) sed -n '7,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "test.sh: unknown argument: $1 (try --help)" >&2; exit 2 ;;
	esac
	shift
done

FAILED=0

echo "==> shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck bin/digital-ocean infra/provision-cpu.sh infra/provision-gpu.sh test.sh release.sh setup.sh install-hooks.sh hooks/pre-push; then
		echo "    clean"
	else
		echo "    shellcheck FAILED"
		FAILED=1
	fi
else
	echo "    shellcheck not installed — skipped"
fi

echo "==> bats"
if ! command -v bats >/dev/null 2>&1; then
	echo "    ERROR: bats not found (dev dependency). Install it:" >&2
	echo "      brew install bats-core           # macOS" >&2
	echo "      sudo apt-get install -y bats      # Debian/Ubuntu" >&2
	echo "      see https://github.com/bats-core/bats-core" >&2
	exit 1
fi
# `bats tests/` is non-recursive: it runs tests/*.bats and skips tests/integration/.
# The integration lane runs only under --integration, and only if it has tests.
BATS_TARGETS=(tests/)
if [[ "$INTEGRATION" -eq 1 ]]; then
	if compgen -G "tests/integration/*.bats" >/dev/null; then
		echo "    (integration lane enabled)"
		BATS_TARGETS+=(tests/integration/)
	else
		echo "    (integration lane enabled — no tests/integration/*.bats yet)"
	fi
fi
if bats "${BATS_TARGETS[@]}"; then
	echo "    tests passed"
else
	echo "    tests FAILED"
	FAILED=1
fi

# --- python lane (demo app) -------------------------------------------------
# The demo app (demo/, COMP-3) is Python/Flask. Its pytest suite runs here,
# mirroring how bats is treated: pytest is a dev dependency. The fast lane
# excludes the `integration` marker (the real-Ollama test); --integration adds
# it back, and those tests self-skip when Ollama is absent.
echo "==> pytest (demo app)"
if [[ -d demo/tests ]]; then
	if ! command -v pytest >/dev/null 2>&1; then
		echo "    ERROR: pytest not found (dev dependency). Install it:" >&2
		echo "      pip install -r demo/requirements.txt -r demo/requirements-dev.txt" >&2
		exit 1
	fi
	if [[ "$INTEGRATION" -eq 1 ]]; then
		echo "    (integration lane enabled — includes real-Ollama tests, self-skipping)"
		PYTEST_OK=0
		pytest demo/tests -q || PYTEST_OK=$?
	else
		PYTEST_OK=0
		pytest demo/tests -q -m "not integration" || PYTEST_OK=$?
	fi
	if [[ "$PYTEST_OK" -eq 0 ]]; then
		echo "    tests passed"
	else
		echo "    tests FAILED"
		FAILED=1
	fi
else
	echo "    no demo/tests — skipped"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
	echo "ALL TESTS PASSED"
else
	echo "TESTS FAILED"
fi
exit "$FAILED"
