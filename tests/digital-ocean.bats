#!/usr/bin/env bats
#
# Tests for the digital-ocean control CLI. Run via ./test.sh (which checks bats
# is installed). The tool must work under BOTH bash and zsh, so we exercise it
# under each.

@test "digital-ocean --help prints usage and exits 0" {
	run ./bin/digital-ocean --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"Usage"* ]]
}

@test "digital-ocean runs a basic invocation" {
	run ./bin/digital-ocean
	[ "$status" -eq 0 ]
	[[ "$output" == *"digital-ocean"* ]]
}

@test "digital-ocean rejects an unknown flag" {
	run ./bin/digital-ocean --nope
	[ "$status" -ne 0 ]
}

@test "digital-ocean runs under bash" {
	run bash ./bin/digital-ocean --help
	[ "$status" -eq 0 ]
}

@test "digital-ocean runs under zsh" {
	if ! command -v zsh >/dev/null 2>&1; then
		skip "zsh not installed"
	fi
	run zsh ./bin/digital-ocean --help
	[ "$status" -eq 0 ]
}
