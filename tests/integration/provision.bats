#!/usr/bin/env bats
#
# Integration (un-mocked) tests for the F5 provisioning scripts. These run each
# script in a REAL ubuntu:22.04 Docker container — the closest thing to a fresh
# droplet available without provisioning paid DO infra (there is no droplet until
# F6). They are opt-in: run only via `./test.sh --integration`, and they self-skip
# when Docker is unavailable, so PR CI stays green without a container runtime.
#
# What they really exercise (the boundaries the fast lane only shimmed):
#   - provision-cpu.sh: real apt install + real venv + real `pip install Flask`.
#   - provision-gpu.sh: the real nvidia-smi assertion NEGATIVE path (a CPU
#     container has no GPU, so the driver assertion must fail fast).
#
# Deferred to F7 (a real droplet): the block-volume mount positive path, the
# GPU-present positive path, the real Ollama install, and the systemd drop-in —
# none of which a base container provides (no attached volume, no GPU, no
# systemd). See design/overview.md.

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

@test "integration: provision-cpu.sh really installs python + venv + Flask on Ubuntu" {
	run docker run --rm -v "$REPO:/repo:ro" \
		-e APP_DIR=/opt/app \
		-e REQUIREMENTS_FILE=/repo/demo/requirements.txt \
		-e DATA_MOUNT=/tmp/data \
		-e FSTAB_FILE=/tmp/fstab \
		"$IMAGE" \
		bash -c 'bash /repo/infra/provision-cpu.sh && /opt/app/.venv/bin/python -c "import flask; print(flask.__version__)"'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "integration: provision-cpu.sh is idempotent on a real box (second run also succeeds)" {
	run docker run --rm -v "$REPO:/repo:ro" \
		-e APP_DIR=/opt/app \
		-e REQUIREMENTS_FILE=/repo/demo/requirements.txt \
		-e DATA_MOUNT=/tmp/data \
		-e FSTAB_FILE=/tmp/fstab \
		"$IMAGE" \
		bash -c 'bash /repo/infra/provision-cpu.sh && bash /repo/infra/provision-cpu.sh'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "integration: provision-gpu.sh asserts the NVIDIA driver and fails fast when absent" {
	run docker run --rm -v "$REPO:/repo:ro" \
		-e NVIDIA_WAIT_SECS=0 \
		-e MODELS_MOUNT=/tmp/models \
		-e FSTAB_FILE=/tmp/fstab \
		"$IMAGE" \
		bash /repo/infra/provision-gpu.sh
	echo "$output"
	[ "$status" -ne 0 ]
	echo "$output" | grep -qi "nvidia"
}
