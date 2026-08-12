#!/usr/bin/env bats
#
# Fast/hermetic tests for the F11 (#27) manifest layer: the flat-YAML reader
# `_manifest_get` and the `--app-dir` resolution / manifest validation that
# `local` and `start` share. The filesystem is the only boundary (a manifest
# file we write into $BATS_TEST_TMPDIR), so nothing real runs here.
#
# NOTE: bats silently ignores a mid-test bare `[[ ]]`; substring checks use
# `grep -q` (a simple command bats DOES catch).

DO=./bin/digital-ocean

# Call the CLI's internal parser without running main (DO_SOURCE_ONLY guard).
_get() { # file key
	DO_SOURCE_ONLY=1 bash -c '. ./bin/digital-ocean; _manifest_get "$1" "$2"' _ "$1" "$2"
}

# Read a per-env deployment key (F12, #29 nested reader).
_getd() { # file env key
	DO_SOURCE_ONLY=1 bash -c '. ./bin/digital-ocean; _manifest_get_deployment "$1" "$2" "$3"' _ "$1" "$2" "$3"
}

setup() {
	APP="$BATS_TEST_TMPDIR/app"
	mkdir -p "$APP"
	# A valid manifest (mirrors demo/digital-ocean.yml, incl. inline comments and
	# a colon inside the model value).
	cat >"$APP/digital-ocean.yml" <<'EOF'
# a comment line, ignored

name: testapp
app_dir: .                 # trailing comment, stripped
entrypoint: app.py
requirements: requirements.txt
port: 5000
health_path: /health
ollama_model: llama3.2:1b   # value keeps its own colon
credentials_env_file: true

deployments:
  prod:
    region: blr1
    ollama_backend: cpu
    app_size: s-2vcpu-4gb
    ollama_cpu_size: s-8vcpu-16gb-amd
    firewall: false
  staging:
    region: tor1
    ollama_backend: gpu
    app_size: s-1vcpu-2gb
    firewall: true
EOF
}

# --- _manifest_get ----------------------------------------------------------

@test "manifest: reads a plain scalar" {
	[ "$(_get "$APP/digital-ocean.yml" entrypoint)" = "app.py" ]
}

@test "manifest: strips an inline trailing comment" {
	[ "$(_get "$APP/digital-ocean.yml" app_dir)" = "." ]
}

@test "manifest: preserves a colon inside the value (model tag)" {
	[ "$(_get "$APP/digital-ocean.yml" ollama_model)" = "llama3.2:1b" ]
}

@test "manifest: reads the port and health path" {
	[ "$(_get "$APP/digital-ocean.yml" port)" = "5000" ]
	[ "$(_get "$APP/digital-ocean.yml" health_path)" = "/health" ]
}

@test "manifest: a missing key yields empty output" {
	[ -z "$(_get "$APP/digital-ocean.yml" nonesuch)" ]
}

@test "manifest: reads the shared name key" {
	[ "$(_get "$APP/digital-ocean.yml" name)" = "testapp" ]
}

# --- _manifest_get_deployment (nested per-env reader, #29) -------------------

@test "deployment: reads a prod key" {
	[ "$(_getd "$APP/digital-ocean.yml" prod region)" = "blr1" ]
	[ "$(_getd "$APP/digital-ocean.yml" prod ollama_backend)" = "cpu" ]
	[ "$(_getd "$APP/digital-ocean.yml" prod app_size)" = "s-2vcpu-4gb" ]
}

@test "deployment: reads a staging key (different section)" {
	[ "$(_getd "$APP/digital-ocean.yml" staging region)" = "tor1" ]
	[ "$(_getd "$APP/digital-ocean.yml" staging ollama_backend)" = "gpu" ]
	[ "$(_getd "$APP/digital-ocean.yml" staging firewall)" = "true" ]
}

@test "deployment: a key present in prod but absent in staging yields empty" {
	# ollama_cpu_size is only under prod; staging must not bleed it through.
	[ -z "$(_getd "$APP/digital-ocean.yml" staging ollama_cpu_size)" ]
}

@test "deployment: a missing env yields empty output" {
	[ -z "$(_getd "$APP/digital-ocean.yml" nosuchenv region)" ]
}

@test "deployment: a missing key in a present env yields empty output" {
	[ -z "$(_getd "$APP/digital-ocean.yml" prod nonesuch)" ]
}

@test "deployment: does not read a shared top-level key as a deployment key" {
	# entrypoint is top-level, not under deployments.<env> — must be empty.
	[ -z "$(_getd "$APP/digital-ocean.yml" prod entrypoint)" ]
}

@test "manifest: strips surrounding double and single quotes" {
	printf 'a: "quoted"\nb: '\''single'\''\n' >"$APP/q.yml"
	[ "$(_get "$APP/q.yml" a)" = "quoted" ]
	[ "$(_get "$APP/q.yml" b)" = "single" ]
}

# --- --app-dir resolution + manifest validation (via local; fails before any
#     Ollama/venv work, so no shims are needed) --------------------------------

@test "local without --app-dir errors (exit 2) and mentions app-dir" {
	run $DO local
	[ "$status" -eq 2 ]
	printf '%s' "$output" | grep -qi 'app-dir'
}

@test "start without --app-dir errors (exit 2) and mentions app-dir" {
	run $DO start
	[ "$status" -eq 2 ]
	printf '%s' "$output" | grep -qi 'app-dir'
}

@test "--app-dir pointing at a missing directory errors" {
	run $DO --app-dir "$BATS_TEST_TMPDIR/nope" local
	[ "$status" -ne 0 ]
	printf '%s' "$output" | grep -qi 'app-dir'
}

@test "--app-dir with no digital-ocean.yml errors (points at the manifest)" {
	mkdir -p "$BATS_TEST_TMPDIR/empty"
	run $DO --app-dir "$BATS_TEST_TMPDIR/empty" local
	[ "$status" -ne 0 ]
	printf '%s' "$output" | grep -qi 'digital-ocean.yml'
}

@test "--app-dir with a manifest missing a required key errors" {
	mkdir -p "$BATS_TEST_TMPDIR/bad"
	# entrypoint omitted (name present, so entrypoint is the first missing key).
	printf 'name: bad\napp_dir: .\nrequirements: requirements.txt\nport: 5000\nhealth_path: /health\nollama_model: m\n' \
		>"$BATS_TEST_TMPDIR/bad/digital-ocean.yml"
	run $DO --app-dir "$BATS_TEST_TMPDIR/bad" local
	[ "$status" -ne 0 ]
	printf '%s' "$output" | grep -qi 'entrypoint'
}

@test "--app-dir with a manifest missing name errors (name is required, #29)" {
	mkdir -p "$BATS_TEST_TMPDIR/noname"
	printf 'app_dir: .\nentrypoint: app.py\nrequirements: requirements.txt\nport: 5000\nhealth_path: /health\nollama_model: m\n' \
		>"$BATS_TEST_TMPDIR/noname/digital-ocean.yml"
	run $DO --app-dir "$BATS_TEST_TMPDIR/noname" local
	[ "$status" -ne 0 ]
	printf '%s' "$output" | grep -qi 'name'
}

@test "--app-dir with an invalid manifest name errors (DNS-safe, #29)" {
	mkdir -p "$BATS_TEST_TMPDIR/badname"
	# Uppercase + underscore are not DNS-label-safe.
	printf 'name: My_App\napp_dir: .\nentrypoint: app.py\nrequirements: requirements.txt\nport: 5000\nhealth_path: /health\nollama_model: m\n' \
		>"$BATS_TEST_TMPDIR/badname/digital-ocean.yml"
	run $DO --app-dir "$BATS_TEST_TMPDIR/badname" local
	[ "$status" -ne 0 ]
	printf '%s' "$output" | grep -qi 'name'
}

@test "--env rejects an unknown environment (exit 2, #29)" {
	run $DO --app-dir "$APP" --env qa local
	[ "$status" -eq 2 ]
	printf '%s' "$output" | grep -qi 'env'
}

@test "--app-dir=DIR (equals form) is accepted by the flag parser" {
	# Reaches manifest validation (missing manifest) rather than an "unknown
	# argument" error — proving the =form parsed.
	run $DO --app-dir="$BATS_TEST_TMPDIR/empty2" local
	printf '%s' "$output" | grep -qiv 'unknown argument'
}
