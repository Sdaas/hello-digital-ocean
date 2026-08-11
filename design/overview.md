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
- **Python test lane (F2):** the demo app's `pytest` suite is wired into
  `./test.sh` alongside bats (pytest treated as a dev dependency, like bats). The
  Ollama network boundary is mocked in the fast lane, which obligates an opt-in,
  self-skipping real-Ollama test under `tests/integration/` (run by
  `./test.sh --integration`); CI installs the demo deps and runs the fast lane.

## Constraints

<!-- Security / performance / scale constraints captured at project start. -->
None recorded at project start. (See `architecture/overview.md` and the ADRs
for design decisions that carry implicit constraints, e.g. cost and networking.)

## Design & Usability Considerations

<!-- Anything shaping design or UX captured at project start. -->
None recorded at project start.
