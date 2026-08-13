# hello-digital-ocean — Design Overview

> The curated, end-to-end design and **key** decisions for hello-digital-ocean.
> Keep this current. Record only decisions that shape the architecture.

## Purpose

Sample setup for running a webapp + Ollama on Digital Ocean infrastructure

## Architecture

The authoritative end-to-end design for this repo was produced upstream by
`/sdlc-discovery` and `/sdlc-architecture`. Do **not** duplicate it here — see:

- Concept & use cases: [`discovery/concept.md`](../discovery/concept.md),
  [`discovery/use-cases.md`](../discovery/use-cases.md)
- Architecture overview (capability map, components, container diagram, cost):
  [`architecture/overview.md`](../architecture/overview.md)
- Feature backlog (F1–F10): [`architecture/components.md`](../architecture/components.md)
- Decision records: [`architecture/decisions/`](../architecture/decisions/) (ADRs 0001–0007)
- Phase status & build order: [`PROGRESS.md`](../PROGRESS.md)

This file remains the home for design notes that emerge during per-feature
`/sdlc-feature` design gates.

## Key Decisions

<!-- One bullet per KEY decision, with a one-line rationale. Not every decision. -->
- Stack profile: shell (cli); distribution: none.
- **Naming:** the main artifact is the **`digital-ocean`** control CLI
  (`bin/digital-ocean`); the **demo app** lives in **`demo/`** and exists to
  showcase that the CLI works. (Repo is named `hello-digital-ocean`; binary is
  `digital-ocean`.)
- Logging: leveled logging — INFO (default) and DEBUG (via `--verbose`), ERROR
  always — to **stderr** (stdout stays data-only), ISO-8601 UTC timestamps. The
  entry point ships with `log_*` / `logging` / `console` helpers demonstrating it.
- **Demo app (F2):** the only runtime dependency is **Flask** — the Ollama client
  is hand-rolled on the stdlib (`urllib`), keeping the deploy/venv lean (ADR-ethos:
  fewest moving parts). Replies are non-streaming.
- **Demo app history (F2):** a single shared conversation persisted as **JSONL**
  (`APP_DATA_DIR/history.jsonl`), appended per turn and reloaded on start so it
  survives a `stop`/restart. Malformed lines are skipped defensively.
- **`digital-ocean local` (F3):** the first *real* subcommand — it introduces a
  small **subcommand dispatcher** in `bin/digital-ocean` that F4–F9 extend. It
  runs the demo app on the Mac from the **same `demo/requirements.txt`** (venv at
  repo-root `.venv/`), **fails fast** if local Ollama is unreachable (before
  building the venv), launches Flask **detached** (`APP_ENV=LOCAL`; pid + captured
  log at `demo/.localdata/local.{pid,log}`), waits for `/health`, then opens the
  browser. `digital-ocean local down` stops it via the pid file. Bats caveat
  worth remembering: a mid-test `[[ ]]` failure is silently ignored, so
  output-substring assertions use `grep -q`.
- **`digital-ocean setup` (F4):** local-only preflight + interview + config write;
  **creates zero billable resources** (only read-only `doctl account get` /
  `compute ssh-key list`). Preflight **accumulates all failures** then **hard-fails
  (exit 1, no config written)** with a fix hint per item. Config is **env-style
  `KEY=value`** at repo-local **`.do/config`** (gitignored, written `0600`,
  sourceable — no `jq` dependency); `DO_CONFIG_DIR` overrides the location for
  tests. Per-key resolution is **env override > stored config > hardcoded
  default**, so `--non-interactive` + env vars drive it headlessly and re-runs are
  idempotent. The creds file is `touch`ed (may be empty, ADR-0005). The doctl
  boundary is stubbed on `PATH` in the fast lane, which obligates the opt-in,
  self-skipping real-`doctl` test in `tests/integration/setup.bats`.
- **Provisioning scripts (F5):** two **self-contained** Ubuntu bash scripts —
  `infra/provision-cpu.sh` (apt `python3-venv/pip` → format-if-empty + mount data
  volume → venv + `pip install -r demo/requirements.txt`) and
  `infra/provision-gpu.sh` (**assert** NVIDIA driver → mount models volume →
  install Ollama). Run as root **over SSH** by F7 (ADR-0002); the CLI never
  shares code with them. Configured by **env vars with ADR defaults**
  (sourceable). Idempotent throughout (re-run skips completed steps). Key design
  points learned from DO/Ollama docs: (1) volumes mount **by device-path**
  `/dev/disk/by-id/scsi-0DO_Volume_<name>` with DO's exact opts
  `defaults,nofail,discard,noatime 0 2` in `/etc/fstab` (not UUID), and are
  **formatted only when unformatted** (never reformat — persistence across
  `stop`, ADR-0001/0003); (2) the GPU driver was originally *asserted* via a
  **bounded poll** of `nvidia-smi` (`NVIDIA_WAIT_SECS`, default 120), on the
  assumption DO's AI/ML image ships it — **superseded by #17**, which installs the
  driver on a plain Ubuntu image before the poll (see the #17 entry below); (3)
  Ollama is pointed at `/mnt/models` and bound
  `0.0.0.0:11434` via a systemd **drop-in** override with `chown ollama:ollama`
  on the volume. F5 stops at "deps installed" — **model pull (C8) and firewalling
  are F7**. The apt/venv/pip/Ollama/nvidia boundaries are PATH-shimmed in the fast
  bats lane, which obligates the opt-in `tests/integration/provision.bats` that
  runs both scripts in a real `ubuntu:22.04` Docker container (self-skips without
  `docker`); the volume-mount **positive path** and GPU-**present** path can only
  be exercised on a real droplet, so their un-mocked VERIFY is **deferred to F7**.
- **DO resource provisioning (F6):** a **hidden** CLI subcommand —
  `digital-ocean provision` (not in `usage`; F7 `start` calls the same helper
  functions, and F8 `stop`/`destroy` tear the resources back down). `provision` **ensures**
  (find-by-name → adopt, else create) a private VPC, the two volumes (data 10 GB
  → CPU, models 50 GB → GPU; ADR-0003), and the CPU + GPU droplets (SSH key by
  name, on the VPC; ADR-0007), **attaches** data→CPU / models→GPU, and records
  everything to **`.do/state`** (env-style `KEY=value`, `0600`, gitignored under
  `.do/`, sourceable — same discipline as F4's `.do/config`; IDs + names + IPs
  that F7/F8/F9 consume). It **reads `.do/config`** and hard-fails with "run
  setup first" if absent. **Idempotent, no double-spend**: adopt-by-name is the
  source of truth; state is rebuilt after each ensure step. Fixed **`hello-do-`**
  resource names (overridable via env/config). Volumes are created **`--fs-type
  ext4`** so a filesystem always exists and the F5 provision scripts' format-if-
  empty is a guaranteed no-op (never reformats — persistence, ADR-0001/0003).
  Attach **skips** when already on the target droplet, **errors** when attached
  elsewhere. **No auto-rollback** on partial failure (re-run adopts, or `stop`/
  `destroy` clean up). Droplet images are **config-driven** (`DO_CPU_IMAGE`
  default `ubuntu-22-04-x64`; `DO_GPU_IMAGE` = DO's AI/ML-ready image, resolved
  at VERIFY). A **source-guard** (`DO_SOURCE_ONLY=1`) lets the helper functions
  be loaded without running `main`, so the real-boundary test can drive them and
  F7 can reuse them. The doctl-**create** boundary is stubbed in the fast lane
  (`tests/do-provision.bats`), which obligates the opt-in, self-skipping
  cheap-real `tests/integration/do-provision.bats` (`DO_REAL_PROVISION=1`; real
  VPC + one small volume: create→adopt→destroy against live DO — **passed**
  2026-08-10); the **attach positive path and real
  droplet create are deferred to F7** (billable/GPU), mirroring F5's deferred
  volume-mount VERIFY.
- **`digital-ocean start` orchestration (F7):** the public end-to-end command that
  ties F4/F5/F6 together. It **reuses F6's `cmd_provision`** (adopt-or-create VPC +
  volumes + droplets + attach → `.do/state`), then ensures **two DO cloud firewalls**
  (`hello-do-cpu-fw`: `:5000`+`:22` public; `hello-do-gpu-fw`: `:11434` from the **VPC
  IP range** only + `:22`) to honor ADR-0007 (Ollama binds `0.0.0.0`, so a firewall —
  not just the VPC — is what keeps `:11434` off the public net); firewall IDs are added
  to `.do/state`. It waits for SSH (**`accept-new`** host keys → `.do/known_hosts`),
  **`rsync`s** `demo/`+`infra/` to `/opt/app` on both droplets, runs the F5
  `provision-gpu.sh` then **`ollama pull`** (C8 — persists on `/mnt/models`, so re-run
  is a no-op), runs `provision-cpu.sh`, **`scp`s the creds** file → `/etc/app/credentials`
  (C9, ADR-0005), and deploys the F2 app as a **systemd `app.service`** (`APP_ENV=DO_DEMO`,
  `OLLAMA_URL=http://<GPU_PRIVATE_IP>:11434` per ADR-0007, `APP_DATA_DIR=/mnt/data`) —
  C10/C11. **Health checks**: Ollama `/api/tags` over the private IP + app `/health`;
  then stdout prints the public URL + paste-ready `ssh` commands (ADR-0006). **Idempotent**
  (re-run adopts/re-syncs/restarts). The `doctl`/`ssh`/`scp`/`rsync`/`ollama` boundaries
  are PATH-shimmed in the fast lane (`tests/do-start.bats`), which obligates the opt-in,
  self-skipping `tests/integration/do-start.bats` (`DO_REAL_START=1`) **plus a billable
  live VERIFY** (the un-mocked GPU/ssh/Ollama evidence F5/F6 deferred here). **F8 handoff:**
  `stop`/`destroy` should also clean up the two firewalls.
- **Selectable Ollama backend + private-IP isolation (#18/#19):** `setup` records
  **`OLLAMA_BACKEND=cpu|gpu`** (default **cpu** — the demo runs GPU-free) and
  **`DO_ENABLE_FIREWALL=0|1`** (default **0**). Topology is unchanged either way
  (2 droplets + VPC); only the **Ollama node** varies — a CPU droplet
  (`DO_OLLAMA_CPU_SIZE`, default **`s-8vcpu-16gb-amd`**, sized for an 8B Q4 model + KV
  cache, provisioned by new **`infra/provision-ollama-cpu.sh`**) or a GPU droplet
  (`DO_GPU_SIZE`, existing `provision-gpu.sh`; #17 owns its driver work). The
  `.do/state` keys stay **`DO_GPU_*`** for the Ollama node regardless of backend
  (no rename — avoids rippling through F6/F7). `cmd_start` branches on
  `OLLAMA_BACKEND` at exactly two points: the Ollama droplet's **size** and which
  **provision script** runs over SSH; everything downstream is backend-agnostic.
  **Ollama isolation is now the private-IP bind** (`OLLAMA_HOST=<node_private_ip>:11434`,
  from state — not `0.0.0.0`), so :11434 is off the public net with **no firewall,
  on the current non-firewall-scoped token** (ADR-0007 amended, #19). `ollama pull`
  runs with the same `OLLAMA_HOST`. The firewall block is gated behind
  `DO_ENABLE_FIREWALL` (default off, skipped); with `=1` the existing VPC-scoped
  firewall path runs, and if the token lacks firewall scope it **hard-fails**
  (points at #16). New CPU-provision boundary (apt/ollama) is PATH-shimmed in the
  fast lane (`tests/provision-ollama-cpu.bats`), obligating the opt-in Docker
  integration test; the CPU live end-to-end (Ollama off the public IP, chat works)
  is the **first real VERIFY of F5+F6+F7**, on cents/hr CPU (GPU path stays
  hermetic-tested here, live-VERIFY'd with #17). **Region constraint (found at
  VERIFY):** the CPU-16GB node needs `s-8vcpu-16gb-amd`, which **tor1 lacks**
  (its standard droplets top out at 8 GB), while the affordable GPU is tor1-only —
  so region must be **backend-aware**. #18 left the region default unchanged;
  **#17 resolves it** (below).
- **GPU backend + backend-aware region (#17):** makes the GPU path real and picks
  regions by backend. A live `doctl` sweep found the only affordable launchable DO
  GPU is the **RTX 6000 Ada (48 GB, $1.57/hr, tor1-only)**; blr1 has no GPU, ams3's
  cheapest is a $4.41/hr H100. Since the H100-flavored base image is the *only*
  public GPU image, the GPU node now boots **plain `ubuntu-22-04-x64`** and
  `provision-gpu.sh` **installs the NVIDIA driver itself** (`ubuntu-drivers`,
  idempotent, skip via `NVIDIA_INSTALL=0`) before the existing assert (ADR-0002
  amended). **Region is now a pure function of the backend** (`_region_for_backend`,
  ADR-0008): **cpu→blr1** (India-local, has the 16 GB node), **gpu→tor1**; an
  explicit `DO_REGION` still overrides, and `setup` re-derives on every run so a
  backend switch can't strand a stale region. Defaults retargeted: `DO_GPU_SIZE`
  →`gpu-6000adax1-48gb`, `DO_GPU_IMAGE`→`ubuntu-22-04-x64`. The apt/NVIDIA install
  is PATH-shimmed in the fast lane (marker-file driver model); the Docker
  integration test keeps exercising the assert **negative** path un-mocked via
  `NVIDIA_INSTALL=0`. **VERIFY status:** CPU@blr1 fully live-verified
  (provision→chat→destroy, ~$0.20/hr) and it exposed+fixed a cross-region VPC
  adoption bug (region-scoped VPC name, above). **GPU@tor1 live VERIFY is deferred
  (#22):** the DO account's GPU limit is 0, so the RTX 6000 Ada droplet cannot yet
  launch — the un-mocked driver-install VERIFY is owed pending a DO support quota
  bump. A separate pre-existing gap (provision doesn't fail-fast on a failed
  droplet create) was filed as #23.
- **`digital-ocean stop` / `destroy` teardown (F8, #7):** the **public** teardown
  surface, replacing the old hidden `deprovision`. `stop` destroys the droplets +
  the two `start`-created firewalls but **keeps** volumes + VPC (compute billing
  stops; data persists for a later `start`); `destroy` also removes volumes + VPC
  and the `.do/state` file, behind a typed-`yes` confirmation (`-y` /
  `--non-interactive` skips it — same flag as `setup`). Both share `_teardown`.
  Two teardown bugs found at the #18/#19 live VERIFY are fixed here: **(1) async
  delete race** — droplet delete is async, so we **poll `doctl droplet get` until
  each droplet is gone** before deleting the volumes it was attached to
  (`DO_DELETE_WAIT_SECS`/`_POLL_SLEEP`, overridable for tests); **(2) default VPC**
  — a VPC auto-promoted to the region default returns `403 Can not delete default
  VPCs`, so `_delete_vpc` **skips-with-warning** rather than erroring (a default
  VPC is free and expected). **Snapshots: no-op** — the project creates none, so
  there is nothing to delete (forward-looking). Teardown is best-effort per
  resource; only a declined confirmation is a hard non-zero exit. The `doctl`
  boundary is PATH-shimmed in the fast lane (`tests/do-provision.bats`, a stub
  extended with async-linger droplet-get + a default-VPC 403 toggle); the
  un-mocked teardown is covered by the real create→adopt→**destroy** in
  `tests/integration/do-provision.bats`, with the full stop/destroy on real
  droplets folded into the billable live VERIFY.
- **`digital-ocean ssh` / `logs` / `status` debug helpers (F9, #8):** thin read-side
  companions to `start`. They **reuse F7's `_ssh`/`_ssh_opts` + pinned `.do/known_hosts`**
  (`StrictHostKeyChecking=accept-new` — the non-interactive host-key handling C18 asks
  for) and the `.do/state` IPs, so the user names a **role (`cpu|gpu`, default `cpu`)**,
  never a host. `ssh` opens an interactive root shell (or runs a one-shot remote command,
  `ssh gpu nvidia-smi`; a non-`cpu|gpu` first arg is a **target error**, not a silent
  command, so a typo can't run on the default host); `logs` tails the service journal
  (`cpu`→`app.service`, `gpu`→`ollama.service`; last 100 or `-f`); `status` reports
  `systemctl is-active` + a health probe (`cpu`→`:5000/health`, `gpu`→`:11434/api/tags`),
  **both nodes** when no role is given. No state file → "run `start` first" (non-zero).
  The ssh boundary is PATH-shimmed in the fast lane (`tests/do-debug.bats`, asserting the
  right IP + remote command per subcommand); the un-mocked evidence is folded into the
  existing billable live VERIFY (`ssh gpu nvidia-smi` / `logs` / `status` on a real host).
- **Python test lane (F2):** the demo app's `pytest` suite is wired into
  `./test.sh` alongside bats (pytest treated as a dev dependency, like bats). The
  Ollama network boundary is mocked in the fast lane, which obligates an opt-in,
  self-skipping real-Ollama test under `tests/integration/` (run by
  `./test.sh --integration`); CI installs the demo deps and runs the fast lane.
- **Manifest-driven app config (F11, #27):** the CLI deploys **any** conforming
  app, not just `demo/`. A per-app **`digital-ocean.yml`** manifest (in the app
  dir) carries the app's facts — `app_dir`, `entrypoint`, `requirements`, `port`,
  `health_path`, `ollama_model`, `credentials_env_file` — and the CLI reads them
  instead of hardcoding `demo/`. `infra/` stays **tool-owned**. Key decisions:
  (1) **`--app-dir <dir>` is required** for `local`/`start` (a **breaking change** —
  no CWD/`demo/` fallback); manifest = `<app-dir>/digital-ocean.yml`.
  (2) **Explicit env contract, no `APP_ENV`:** the CLI sets `HOST`/`PORT`/`OLLAMA_URL`/
  `OLLAMA_MODEL`/`APP_DATA_DIR`/`APP_CREDENTIALS_FILE` **explicitly** (local: 127.0.0.1;
  cloud: 0.0.0.0) — `config.py` already lets each override its profile default, so the
  demo binds identically without the demo-specific `APP_ENV=DO_DEMO`/`LOCAL`.
  (3) **`ollama_model` moves out of `.do/config`/`setup` into the manifest** (it is a
  per-app fact); `start` reads it from the manifest.
  (4) App code always lands at **`/opt/app/app`** (rsync of `<app_dir>`), `infra/` at
  `/opt/app/infra`; `ExecStart=/opt/app/.venv/bin/python /opt/app/app/<entrypoint>`.
  (5) `start` records **`APP_PORT` + `APP_HEALTH_PATH` in `.do/state`** so the F9
  `status`/`logs` helpers stay manifest-free (they read the deployed truth from state).
  (6) YAML is parsed by a **minimal flat `key: value`** reader in pure sh (no
  `jq`/`yq` — matches the repo's dependency-light ethos); a code note flags that a
  real YAML parser is warranted **only if** the manifest grows nested structure (YAGNI).
  `demo/digital-ocean.yml` is the reference manifest; the demo runs via `--app-dir demo`.
- **Manifest `name` + environments (F12, #29):** resource names are derived from
  the app, not hardcoded `hello-do-*`, so two apps (or two envs of one app) never
  collide. The manifest gains a required **`name:`** (DNS-safe `[a-z0-9-]`, e.g.
  `demo`) and a **`deployments:`** map keyed by environment — **`prod`** (default)
  and **`staging`**. A global **`--env prod|staging`** flag (default `prod`) selects
  the deployment; **one spelling everywhere** (map key = CLI value = name token),
  so no long/short mapping. Key decisions:
  (1) **Naming** derives from `<name>-<env>-…`: app node `<name>-<env>-backend`,
  ollama node `<name>-<env>-ollama-<ollama_backend>` (`-cpu`/`-gpu`), volumes
  `<name>-<env>-data|models`, VPC `<name>-<env>-vpc-<region>` (VPC keeps its
  region suffix — a DO VPC binds to one region, #17). Each is still env-overridable
  (`DO_CPU_NAME` etc.); the defaults just changed.
  (2) **The manifest is the source of truth for per-env infra** — `region`,
  `ollama_backend` (`cpu|gpu`; the **app** node is always CPU, only the **ollama**
  node varies — hence the `ollama_` prefix), `app_size`, `ollama_cpu_size`,
  `ollama_gpu_size`, `firewall` — read from `deployments.<env>`. **Shared** app
  facts (`app_dir`/`entrypoint`/`requirements`/`port`/`health_path`/`ollama_model`)
  stay top-level. Precedence: **env var > manifest `deployments.<env>` > built-in
  default**; when an env var wins, the CLI **logs the override** (source + old→new)
  for debuggability.
  (3) **`.do/config` shrinks to machine/account-local** — only `DO_SSH_KEY_NAME` +
  `APP_CREDENTIALS_FILE` (a local secrets path, deliberately **not** in the
  committed manifest). `setup` drops the region/sizes/backend/firewall interview
  and stays app/env-agnostic.
  (4) **Per-env run-state:** `.do/state.<env>` (`.do/state.prod`,
  `.do/state.staging`) so prod and staging never clobber each other's IDs.
  `provision`/`start` need `--app-dir` **and** `--env`; `stop`/`destroy`/`status`/
  `ssh`/`logs` need only `--env` (they read IDs from the state file).
  (5) YAML nesting is read by a **minimal 2-level pure-sh reader**
  (`_manifest_get_deployment`) — still no `jq`/`yq` (the F11 YAGNI note anticipated
  this). No backward-compat (no live deploys predate this). Verified with `demo/`
  (`name: demo`, `prod`/`staging` deployments); live VERIFY `--app-dir demo --env prod`.
- **DO Project grouping (F13, #30):** provisioned resources are grouped under a DO
  **Project** named `<name>-<env>` (e.g. `demo-prod`) instead of the account default
  "first-project", so the console and billing views are organized per app/env.
  `ensure_project` adopts-by-name or creates (`--purpose` + an env-mapped
  `--environment` badge: prod→Production, staging→Staging), then the droplets +
  volumes are assigned by URN (`do:droplet:<id>` / `do:volume:<id>`; **VPCs aren't
  project resources**). Runs at the end of `provision` (which `start` calls); the
  project id/name land in `.do/state.<env>`; `status` notes the project. Key
  decisions: (1) **best-effort** — a token lacking `project` scope (cf. #16's
  firewall scope) only **warns**, never fails an already-billable `provision`
  (grouping is cosmetic, resources still work in the default project); (2) `destroy`
  **leaves the emptied project** in place (Projects are free); (3) resources are
  assigned **one per call** (zsh has no word-splitting, so a single multi-`--resource`
  string wouldn't expand). The `doctl projects` boundary is PATH-stubbed in the fast
  lane, obligating the opt-in real-`doctl` project create/assign test in
  `tests/integration/do-provision.bats` + the batched live VERIFY.
- **HTTPS via Caddy + sslip.io + Let's Encrypt (F14, #31):** the live deploy
  terminates **HTTPS** on the app (CPU) node so the browser gets a secure origin
  (`getUserMedia`/mic works). A tool-owned `infra/provision-caddy.sh` (same idiom as
  the other `provision-*.sh`: root-over-SSH, idempotent, env-configured) installs
  **Caddy** from its official apt repo and writes a Caddyfile whose site address is
  `<dashed-ip>.sslip.io` (e.g. `64-227-154-8.sslip.io`) reverse-proxying to the app
  on `127.0.0.1:$APP_PORT`. **sslip.io** is wildcard DNS that encodes the droplet IP
  in the hostname (no owned domain); **Caddy** auto-obtains + renews a **Let's
  Encrypt** cert via ACME and redirects `:80`→`:443`. Key decisions: (1) **always
  on** — every live deploy gets HTTPS, no manifest flag; (2) the app **binds
  loopback** (`HOST=127.0.0.1`, was `0.0.0.0`) so only Caddy's `:80/:443` are public
  — the plain-http app port is gone; (3) **fail hard** — if Caddy/ACME setup fails,
  `start` errors (no insecure http fallback), matching the "not healthy = not Done"
  teardown discipline; (4) `start` stdout now prints `https://<dashed-ip>.sslip.io`
  (recorded as `APP_URL` in `.do/state.<env>`); internal health/`status` probes stay
  on `http://127.0.0.1:$APP_PORT`. Testing: apt/systemd are PATH-shimmed in the fast
  lane (`tests/provision-caddy.bats`), obligating a real-container integration test
  (`tests/integration/provision-caddy.bats` — real apt install + `caddy validate`);
  the **LE ACME + sslip.io + browser-trust** boundary is only provable live, so it
  lands at the billable VERIFY (LE **staging** while iterating via
  `DO_TLS_ACME_STAGING=1`, then production LE for the trusted-cert acceptance).
  Ships **`docs/tls-setup-guide.md`**. App-agnostic; verified with `demo/`.

## Constraints

<!-- Security / performance / scale constraints captured at project start. -->
None recorded at project start. (See `architecture/overview.md` and the ADRs
for design decisions that carry implicit constraints, e.g. cost and networking.)

## Design & Usability Considerations

<!-- Anything shaping design or UX captured at project start. -->
None recorded at project start.
