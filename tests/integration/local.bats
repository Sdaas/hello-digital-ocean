#!/usr/bin/env bats
#
# Opt-in, UN-MOCKED end-to-end for `digital-ocean local` (F3, generalized in
# F11/#27). Runs the REAL flow against the demo app (--app-dir demo): builds the
# venv from the manifest's requirements, launches the app with the explicit env
# contract (HOST/PORT/OLLAMA_* from the manifest), hits the real /health, then
# tears down. The required real-boundary counterpart to the mocked fast lane
# (tests/local.bats).
#
# Self-skips when local Ollama isn't reachable, so `./test.sh --integration`
# stays green without a running model backend. Home is LOCAL / nightly; PR CI
# runs the fast lane only.

DO=./bin/digital-ocean

setup() {
	export DO_LOCAL_NO_BROWSER=1 # headless: don't pop a browser during tests
	command -v curl >/dev/null 2>&1 || skip "curl not available"
	curl -fsS --max-time 2 "${OLLAMA_URL:-http://localhost:11434}/api/tags" >/dev/null 2>&1 ||
		skip "local Ollama not reachable — start it with: ollama serve"
}

teardown() {
	./bin/digital-ocean --app-dir demo local down >/dev/null 2>&1 || true
}

@test "local: starts app, /health reports LOCAL + ollama_reachable, down stops it" {
	run $DO --app-dir demo local
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "127.0.0.1:5000"

	# /health answers 200 and reports the LOCAL profile with Ollama reachable.
	run curl -fsS --max-time 3 http://127.0.0.1:5000/health
	[ "$status" -eq 0 ]
	echo "$output" | grep -Eq '"app_env": *"LOCAL"'
	echo "$output" | grep -Eq '"ollama_reachable": *true'

	# Teardown stops it cleanly...
	run $DO --app-dir demo local down
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "stopped"

	# ...and a second down is a friendly no-op.
	run $DO --app-dir demo local down
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "not running"
}
