# hello-digital-ocean

Sample setup for running a webapp + Ollama on Digital Ocean infrastructure

---

## Purpose

Sample setup for running a webapp + Ollama on Digital Ocean infrastructure.

The **main artifact** of this repo is **`digital-ocean`** — a Mac-side control
CLI that provisions and tears down the DigitalOcean infrastructure (a CPU
droplet + a GPU droplet + persistent volumes) and runs an app on it:

```bash
digital-ocean setup                        # one-time local preflight + config
digital-ocean --app-dir demo start         # provision the infra and bring the app up
digital-ocean stop                         # destroy droplets, keep volumes (pause billing)
digital-ocean destroy                      # remove everything
digital-ocean --app-dir demo local         # run the app on your Mac, no cloud
```

> These `digital-ocean …` examples assume the CLI is on your `PATH`. From a
> fresh clone the binary lives at `./bin/digital-ocean`; symlink it once to run
> it from anywhere (see [Quick Start](#quick-start)).

The CLI deploys **any conforming app**, not a single bundled one. You point it at
an app with **`--app-dir <dir>`** (required by `local` and `start`); that
directory must hold a **`digital-ocean.yml`** manifest describing the app (see
[App manifest](#app-manifest)). To prove the CLI works, the repo ships a small
**demo app** in [`demo/`](demo/) — a self-contained chatbot (web UI + Flask
backend that keeps conversation history + Ollama model backend) with its own
[`demo/digital-ocean.yml`](demo/digital-ocean.yml). The demo is the *reference
workload*: once the lifecycle is proven against it, a real application drops in
behind the same infrastructure by shipping its own manifest.

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

## Before you run `setup`

`digital-ocean setup` preflights your machine, but you'll have a smoother first
run if these are in place first. Tick each one — the "how" for the DigitalOcean-
specific items is in [Setup](#setup) below.

- [ ] **macOS** control host with **Homebrew** — the CLI targets macOS (see
      [Platform support](#platform-support)).
- [ ] **git** and **gh** (GitHub CLI), and `gh` is **authenticated**
      (`gh auth status`). Run `./setup.sh --verify` to check.
- [ ] **doctl** installed (`brew install doctl`) and authenticated
      (`doctl auth init` → `doctl account get` succeeds). See
      [DigitalOcean access](#digitalocean-access-doctl) for the token + scopes.
- [ ] An **SSH keypair** that exists in **both** places — locally at
      `~/.ssh/id_ed25519` (or `id_rsa`, or `DO_SSH_KEY_FILE`) **and** registered
      on DigitalOcean under the name you'll set as `DO_SSH_KEY_NAME`. See
      [SSH key](#ssh-key).
- [ ] You understand this creates **billable** cloud resources when you run
      `start` — read [Cost](#cost) and plan to `stop`/`destroy` afterward.

Everything above is **local and free**. No DigitalOcean resources are created
until you run `digital-ocean start`.

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

### DigitalOcean access (`doctl`)

The cloud commands drive DigitalOcean through **`doctl`**. Install it
(`brew install doctl`), then authenticate with a personal access token created at
<https://cloud.digitalocean.com/account/api/tokens/new>:

```bash
doctl auth init      # paste the token when prompted (stored in ~/.config/doctl)
doctl account get    # sanity check — prints your account, no error
```

**Token scopes.** *Full Access* works and is simplest for a throwaway demo. For a
least-privilege **custom-scoped** token, grant:

| Resource | Scopes | Why |
|---|---|---|
| `account` | read | doctl's auth check (`account get`) |
| `droplet` | create, read, update, delete | CPU + GPU droplets (F6/F7/F8) |
| `block_storage` | create, read, update, delete | the two volumes (F6) |
| `block_storage_action` | create, read | attach/detach + check attachment (F6) |
| `vpc` | create, read, update, delete | the private VPC (F6, ADR-0007) |
| `snapshot` | read, delete | `destroy` teardown (F8) |
| `ssh_key` | read | resolve `DO_SSH_KEY_NAME` → key ID (F6/F7) |
| `image`, `regions`, `sizes` | read | image/region/size validation (F7) |

The token is a secret — it lives in `~/.config/doctl`, **never** in the repo or
`.do/`.

### SSH key

`digital-ocean setup` requires one SSH keypair that exists in **two** places, and
its preflight fails until both are present:

1. **Locally** — the CLI uses the private key to `ssh`/`rsync`/`scp` into the
   droplets. It looks for `~/.ssh/id_ed25519` or `~/.ssh/id_rsa` (override the
   path with `DO_SSH_KEY_FILE`).
2. **Registered on DigitalOcean** — the *public* key is injected into every
   droplet at create time so the private key above can log in.

Both must be the **same keypair**. If you don't already have one on the scan
path, generate a dedicated key and register it:

```bash
# 1. Generate a local ed25519 keypair at ~/.ssh/id_ed25519(.pub).
ssh-keygen -t ed25519 -C "hello-digital-ocean" -f ~/.ssh/id_ed25519

# 2. Register the PUBLIC half with DigitalOcean under a name you'll recognize.
#    (Needs a token with `ssh_key: create`, or add it in the DO web console:
#     Settings → Security → SSH keys.)
doctl compute ssh-key import hello-do-key --public-key-file ~/.ssh/id_ed25519.pub

# 3. Confirm DigitalOcean now lists it.
doctl compute ssh-key list
```

The name you register (`hello-do-key` above) is what `setup` stores as
`DO_SSH_KEY_NAME` in `.do/config`; `provision`/`start` resolve that name to the DO
key ID. To **reuse an existing key** instead, register that key's `.pub`, then
make sure `DO_SSH_KEY_NAME` matches its DO name **and** the matching private key
is at `~/.ssh/id_ed25519`/`id_rsa` or pointed to by `DO_SSH_KEY_FILE`.

> The `ssh_key` scope in the token table above is `read` — enough for
> `provision`/`start` to resolve the key. Importing a key with `doctl` (step 2)
> additionally needs `ssh_key: create`; the DO web console needs no token scope.

## User Guide

<!-- How an end user runs and uses digital-ocean. -->
Run `digital-ocean --help` (or `./bin/digital-ocean --help` from a fresh clone)
for the built-in usage. The full reference:

### Command reference

Usage: `digital-ocean [--help] [--verbose] [--app-dir <dir>] [<command>]`. With no
command it prints a short banner.

| Command | Billing | What it does |
|---|---|---|
| `setup` | local · free | One-time preflight + interview → writes `.do/config`. Add `--non-interactive` to accept defaults/env with no prompts. |
| `local` | local · free | Run the app on your Mac (venv + browser). **Needs `--app-dir`.** |
| `local down` | local · free | Stop the locally running app. |
| `start` | **BILLABLE** | Provision DO infra + deploy the app end-to-end; prints the public URL + ssh commands when healthy. Idempotent (re-run to adopt + redeploy). **Needs `--app-dir`.** |
| `stop` | frees compute | Tear down droplets + firewalls; **keep** volumes + VPC so a later `start` reuses the data. Stops compute billing. |
| `destroy` | frees all | Full teardown: droplets + firewalls + volumes + VPC (**all data lost**). Prompts to confirm; `-y` / `--non-interactive` skips the prompt. |

**Debug helpers** (need a running host — see `start`):

| Command | What it does |
|---|---|
| `ssh [cpu\|gpu] [cmd...]` | Open a root shell on the droplet (default `cpu`), or run `cmd` there one-shot — e.g. `digital-ocean ssh gpu nvidia-smi`. |
| `logs [cpu\|gpu] [-f]` | Tail the service journal (`cpu`=app, `gpu`=ollama; default `cpu`). `-f`/`--follow` streams instead of the last 100 lines. |
| `status [cpu\|gpu]` | Service state + health probe. No target → probes **both** nodes. |

**Global flags:** `--help` prints usage; `--verbose` enables verbose logging;
`--app-dir <dir>` selects the app to run/deploy (the dir holding
`digital-ocean.yml`; required by `local`/`start`, also settable via `$DO_APP_DIR`).

### App manifest

`local` and `start` deploy the app named by `--app-dir <dir>`. That directory
must contain a **`digital-ocean.yml`** manifest — the CLI reads it instead of
assuming anything app-specific. The reference is
[`demo/digital-ocean.yml`](demo/digital-ocean.yml):

```yaml
app_dir: .                 # app code root, relative to this manifest (rsynced to /opt/app/app)
entrypoint: app.py         # python entrypoint, relative to app_dir
requirements: requirements.txt   # pip -r target, relative to app_dir
port: 5000                 # port the app binds/serves on
health_path: /health       # readiness endpoint (must report app + Ollama health)
ollama_model: llama3.2:1b  # model the app needs (pulled on the Ollama node)
credentials_env_file: true # ship /etc/app/credentials as a systemd EnvironmentFile
```

The CLI drives the app purely through an **environment contract**: it sets
`HOST`/`PORT`, `OLLAMA_URL`/`OLLAMA_MODEL`, `APP_DATA_DIR`, and (when
`credentials_env_file` is on) loads `/etc/app/credentials`. Your app reads those
env vars — locally it binds `127.0.0.1:<port>`, on DO `0.0.0.0:<port>`. `infra/`
stays tool-owned; only the manifest changes per app.

**Backend & region.** `start` defaults to the cheap CPU Ollama backend
(`OLLAMA_BACKEND=cpu`, provisioned in `blr1`). Set `OLLAMA_BACKEND=gpu` for the
GPU backend (provisioned in `tor1`). An explicit `DO_REGION` overrides the
backend-derived region.

### Lifecycle commands (start / stop / destroy)

```bash
# One-time, local only (no billable resources): preflight + interview + .do/config.
digital-ocean setup            # add --non-interactive to accept defaults/env

# Provision DO infra + deploy the app end-to-end (BILLABLE — creates droplets).
# Prints the public app URL + ready-to-paste ssh commands. Idempotent (re-run to
# adopt + redeploy). Defaults to the cheap CPU Ollama backend (OLLAMA_BACKEND=cpu).
digital-ocean --app-dir demo start
```

**Tearing it down.**

```bash
digital-ocean stop        # destroy the droplets + firewalls, KEEP the volumes + VPC
digital-ocean destroy     # full teardown: also delete the volumes + VPC (confirms first)
digital-ocean destroy -y  # same, without the confirmation prompt
```

`stop` stops the compute billing but keeps your data on the volumes, so a later
`digital-ocean start` re-adopts them. `destroy` removes everything (all data lost);
it prompts for a typed `yes` unless you pass `-y` / `--non-interactive`. Both wait
for the droplets to finish deleting before touching the volumes, and both tolerate
a *default* VPC (which DigitalOcean will not delete — harmless, VPCs are free).

> **Always tear down after a demo** — running droplets bill by the hour. See
> [Cost](#cost).

### Cost

`start` creates **billable** DigitalOcean resources that bill *by the hour while
they exist*. With the default CPU backend (`OLLAMA_BACKEND=cpu`) `start`
provisions:

| Resource | Default size slug | Notes |
|---|---|---|
| Control droplet (app) | `s-2vcpu-4gb` | Runs the app. |
| Ollama node (CPU backend) | `s-8vcpu-16gb-amd` | Replaced by a GPU droplet when `OLLAMA_BACKEND=gpu`. |
| Ollama node (GPU backend) | `gpu-6000adax1-48gb` | Only with `OLLAMA_BACKEND=gpu`; the priciest line item by far. |
| Block-storage volumes | 2 volumes | Persist across `stop`; billed per-GiB until `destroy`. |

Order of magnitude: the CPU backend is a few US cents per hour of compute; the
**GPU backend costs roughly an order of magnitude more** per hour. Exact prices
change — check DigitalOcean's pricing pages for the current rate of each slug:

- Droplets & GPU droplets: <https://www.digitalocean.com/pricing/droplets>
- Block storage volumes: <https://www.digitalocean.com/pricing/block-storage>

To stop spending:

- `digital-ocean stop` — frees the (expensive) compute but **keeps** the volumes,
  which keep billing at the small per-GiB rate.
- `digital-ocean destroy` — frees **everything**, including the volumes. Nothing
  left to bill.

> Rule of thumb: **`stop` or `destroy` the moment a demo is over.** A GPU droplet
> left running overnight is the one line item that stings.

## Platform support

The **`digital-ocean` control CLI runs on macOS** — that's what it's developed
and tested on. A Linux control host is not currently supported; known macOS
assumptions you'd hit there:

- **`local` / `start`** open your browser with macOS `open`. On Linux the app
  still runs; you'd just open the printed URL yourself (or set
  `DO_LOCAL_NO_BROWSER=1`).
- **`./setup.sh`** installs dependencies via Homebrew (`brew`); on other
  platforms it only *reports* what to install by hand.

The **droplets** provisioned in the cloud are **Ubuntu** — that's the intended
Linux surface, provisioned automatically over SSH (`infra/`). You interact with
them through `ssh`/`logs`/`status`, so you don't administer them by hand.

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

**Billable real-boundary tests are double-gated.** A test that creates *real*
(billable) DigitalOcean resources also requires an explicit opt-in env var, so
`./test.sh --integration` never spends money by accident. The F6 resource-
provisioning check is one:

```bash
# creates a throwaway VPC + 1 GiB volume, proves adopt-by-name, destroys both
DO_REAL_PROVISION=1 bats tests/integration/do-provision.bats
```

It self-skips unless `doctl` is authenticated **and** `DO_REAL_PROVISION=1` is
set. Cost is about a cent (resources live for seconds and self-clean).

## Release Process

Releases are automated through `release.sh` (bump version, tag, push).
Distribution: **none**.
