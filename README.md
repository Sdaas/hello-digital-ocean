# hello-digital-ocean

Sample setup for running a webapp + Ollama on Digital Ocean infrastructure

---

## Purpose

Sample setup for running a webapp + Ollama on Digital Ocean infrastructure.

The **main artifact** of this repo is **`digital-ocean`** — a Mac-side control
CLI that provisions and tears down the DigitalOcean infrastructure (a CPU
droplet + a GPU droplet + persistent volumes) and runs an app on it:

```bash
digital-ocean setup      # one-time local preflight + config
digital-ocean start      # provision the infra and bring the demo up
digital-ocean stop       # destroy droplets, keep volumes (pause billing)
digital-ocean destroy    # remove everything
digital-ocean local      # run the app on your Mac, no cloud
```

> These `digital-ocean …` examples assume the CLI is on your `PATH`. From a
> fresh clone the binary lives at `./bin/digital-ocean`; symlink it once to run
> it from anywhere (see [Quick Start](#quick-start)).

To prove the CLI actually works, the repo ships a small **demo app** in
[`demo/`](demo/) — a self-contained chatbot (web UI + Flask backend that keeps
conversation history + Ollama model backend). The demo app is the *reference
workload*: once the `digital-ocean` lifecycle is proven against it, a real
application can be dropped in behind the same infrastructure unchanged.

This is a cli (shell). It is developed using an agentic SDLC:
interview → design → test-first code → review → ship, with a human in the loop.

## Repository structure

| Path | What it is |
|---|---|
| **`bin/digital-ocean`** | **Main artifact** — the control CLI (macOS). |
| **`demo/`** | The **demo app** (Flask + chat UI + Ollama client) that showcases the CLI. Built in feature F2. |
| **`infra/`** | Ubuntu provisioning scripts run over SSH on the droplets. Built in F4/F5. |
| `discovery/`, `architecture/` | Approved SDLC discovery + architecture artifacts (concept, use cases, ADRs, backlog). |
| `design/overview.md` | Curated design pointer into the above. |
| `tests/`, `test.sh` | Test suite and single entrypoint. |
| `PROGRESS.md` | Phase status and feature build order (F1–F10). |

> The repo is *named* `hello-digital-ocean`; the *binary* is `digital-ocean`.

## Quick Start

```bash
git clone <repo-url>
cd hello-digital-ocean
./setup.sh             # check / install developer dependencies
./install-hooks.sh     # install the pre-push test gate
./test.sh              # run the tests
./bin/digital-ocean --help        # run it once to confirm a fresh clone works
```

That third line — **run it once** — is the onboarding smoke: a fresh clone should
be able to run the tool, not just pass tests. If it can't, something (a missing
runtime dependency, a broken entry point) is wrong even when the suite is green.

**Put `digital-ocean` on your PATH** (optional but assumed by the examples in
this README) so you can run it from anywhere instead of typing `./bin/…`:

```bash
ln -s "$PWD/bin/digital-ocean" /usr/local/bin/digital-ocean
digital-ocean --help
```

## Setup

This is a **shell** project. Developer dependencies:

- **git**, **gh** (GitHub CLI) — version control and the issue backlog.
- plus the toolchain your test suite needs (see the `Dev dependency:` note at
  the top of `test.sh`).

Run the checker to see what's missing and install it (macOS/Homebrew):

```bash
./setup.sh          # prompts before installing anything
./setup.sh --yes    # install without prompting (CI / non-interactive)
./setup.sh --verify # also run per-dep readiness checks (auth, versions)
```

The plain run checks each tool is **installed**. `--verify` additionally runs
**readiness checks** for the deps that declare one — by default `gh` must be
authenticated (`gh auth status`); a failed check prints the fix and exits
non-zero. Declare checks in the `CHECKS` table near the top of `setup.sh`
(`auth` = a probe that must succeed; `version` = an installed-version floor).

On other platforms `setup.sh` reports what to install by hand.

## User Guide

<!-- How an end user runs and uses digital-ocean. Filled in as features land. -->
Run `digital-ocean --help` (or `./bin/digital-ocean --help` from a fresh clone)
for usage. Full command reference and the
"Before you run `setup`" prerequisites checklist land with the docs feature (F10).

## Developer Guide

<!-- Layout, how to add a feature, conventions. See design/overview.md. -->
The end-to-end design and key decisions live in [`design/overview.md`](design/overview.md).

## Automated Testing Guide

All tests run through a single entrypoint:

```bash
./test.sh
```

This is what CI calls — green locally means green on push.

### Integration (real-boundary) tests

Tests that cross a real boundary — a live service, secrets, a GPU — live in an
**opt-in integration lane**, excluded from the default run so PR CI stays green
without that infrastructure:

```bash
./test.sh --integration    # runs the full suite, incl. the integration lane
```

The lane's home is **local**: the **pre-push hook runs `./test.sh --integration`**
automatically before every push. Write integration tests to **self-skip when
their boundary is absent** (e.g. the service isn't running) so the hook stays
non-blocking — a skipped test is a visible nudge, not a wall. `git push
--no-verify` bypasses the hook if you must.

## Release Process

Releases are automated through `release.sh` (bump version, tag, push).
Distribution: **none**.
