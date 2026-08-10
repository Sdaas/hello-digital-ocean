# Use-Case Catalog — DigitalOcean Demo Host (`digital-ocean` CLI + `demo` app)

> Status: DRAFT for use-case-gate review
> Traces to: `concept.md`
>
> **Rename (2026-08-10):** control CLI `demo` → **`digital-ocean`**; reference
> chatbot → **the `demo` app** (`demo/`).

Primary actor for UC1–UC4 is the **Operator** (Mac terminal). UC5 is the
**Demo tester** (browser). UC6 is **Operator + Claude** (debugging).

**Cross-cutting (all commands):** support `--help` and `--verbose`; strict-mode
shell; idempotent re-runs; the control script runs on macOS only, droplet
provisioning on Ubuntu only.

---

## UC1 — Setup (local-only, one-time) · Priority: P0
- **Trigger:** Operator runs `digital-ocean setup`.
- **Pre:** Mac has `doctl`, `ssh`, `jq`, `rsync`; a credentials file exists
  locally (may be empty if the app needs no third-party APIs).
- **Main flow:**
  1. Preflight: local tools installed (report any missing + the `brew` command
     to install them); `doctl account get` works; an SSH key exists and is
     registered with DO; the credentials file is readable.
  2. Interview: region (GPU-capable), CPU size, GPU size, model name, volume
     sizes, SSH key path, credentials file path.
  3. Write a **local config file** (+ empty local state file). No cloud calls
     that create resources.
- **Post:** A valid local config exists; nothing provisioned in DO yet.
- **Done when:** `digital-ocean setup` on a fresh Mac ends with a config file and a
  green preflight, having created **zero** billable resources.

## UC2 — Start (apply config → live demo) · Priority: P0
- **Trigger:** Operator runs `digital-ocean start`.
- **Pre:** `setup` has produced a config; volumes may or may not exist yet.
- **Main flow:**
  1. Ensure both volumes exist (create on first run; reuse otherwise).
  2. Create CPU + GPU droplets with the SSH key injected; attach volumes at
     `/mnt/data` (CPU) and `/mnt/models` (GPU); create log dirs.
  2a. Provision each droplet **over SSH** from its manifest (`provision-cpu.sh`
     → apt + venv + `demo/requirements.txt`; `provision-gpu.sh` → Ollama, assert
     NVIDIA driver). Idempotent — a fresh box every start.
  3. Install/start Ollama (GPU) with `OLLAMA_MODELS=/mnt/models`; **first run
     only:** `ollama pull` the model onto the volume.
  4. Copy the credentials file from local to `/etc/app/credentials` (CPU).
  5. Deploy the `demo` app to CPU (`APP_ENV=DO_DEMO`, `APP_CREDENTIALS_FILE`,
     Ollama host = GPU IP, history dir = `/mnt/data`); start Flask (serves UI +
     API on port 5000).
  6. Health checks: Ollama up, backend `/health` OK, one end-to-end chat turn.
  7. Print the UI URL and ready-to-paste SSH commands.
- **Post:** Chatbot reachable at a public URL; GPU serving the model.
- **Done when:** Operator opens the printed URL and gets a model reply to a
  typed message.

## UC3 — Stop (pause, save cost) · Priority: P0
- **Trigger:** Operator runs `digital-ocean stop`.
- **Pre:** A demo is running.
- **Main flow:** Destroy both droplets; **keep both volumes** (models, history,
  logs) and the local config/state; update state.
- **Post:** No droplets billing; only volumes (~$15/mo) remain.
- **Done when:** `doctl compute droplet list` shows none, the volume still holds
  the model, and a later `start` restores a working demo **without**
  re-downloading — **and prior conversation history is still present.**

## UC4 — Destroy (remove everything) · Priority: P0
- **Trigger:** Operator runs `digital-ocean destroy`.
- **Pre:** Resources exist.
- **Main flow:** Confirm (irreversible) → destroy droplets **and** volumes +
  snapshots → clear cloud state. Local config kept for a fresh re-start.
- **Post:** Zero billable resources for this demo remain.
- **Done when:** Account shows no droplets/volumes/snapshots for the demo and
  billing for it stops.

## UC5 — Chat via the web UI · Priority: P1
- **Trigger:** Demo tester opens the UI URL after `start`.
- **Pre:** `start` completed; URL known.
- **Main flow:** Tester types a message → backend appends to conversation
  history → calls Ollama → renders the reply; history is shown and persisted.
- **Post:** A multi-turn conversation works and its history is saved to
  `/mnt/data`.
- **Done when:** A tester holds a multi-turn conversation and the reply reflects
  earlier turns (history is honored).

## UC7 — Run the `demo` app locally (local-first verification) · Priority: P0
- **Trigger:** Operator runs `digital-ocean local` on the Mac.
- **Pre:** Ollama installed + running locally; python3 present; a model pulled
  locally (or the command pulls it).
- **Main flow:** Ensure a local venv from the **same `demo/requirements.txt`**;
  assert local Ollama reachable; start Flask with `APP_ENV=LOCAL` (Ollama host =
  localhost, history dir + logs under a local path, creds from a local file);
  open the browser at the local URL.
- **Post:** The identical `demo` app runs entirely on the laptop, no DO resources.
- **Done when:** The same app + same `demo/requirements.txt` serves a working chat at
  `localhost` — proving the repo runs locally *and* on DO from one codebase, and
  that dependencies are fully tracked. (`digital-ocean local down` stops it.)

## UC6 — Debug access (Operator + Claude) · Priority: P1
- **Trigger:** Something misbehaves; Operator or Claude needs to inspect a box.
- **Pre:** Droplets running; IPs in the state file; SSH key present.
- **Main flow:** `digital-ocean ssh cpu|gpu` opens a shell; `digital-ocean logs cpu|gpu` tails
  the persistent log dir; `digital-ocean status` shows droplet/volume/health state.
  Claude drives the same `ssh`/`scp` non-interactively from its tools.
- **Post:** Logs/files/commands on both droplets are reachable for diagnosis.
- **Done when:** From the Mac, a single command lands a shell on either droplet
  and shows its logs without interactive prompts.

---

## Traceability check
| Use case | Priority | Served later by (capability — filled in architecture) |
|---|---|---|
| UC1 Setup | P0 | preflight, interview, local-config |
| UC2 Start | P0 | droplet-create, dependency-provisioning, storage, model-fetch, credentials-injection, app-deploy, health-check |
| UC3 Stop | P0 | teardown-keep-volumes |
| UC4 Destroy | P0 | full-teardown |
| UC5 Chat via UI | P1 | app-runtime (Flask+UI, history, Ollama) |
| UC7 Run locally | P0 | local-run orchestration, app-runtime, APP_ENV |
| UC6 Debug access | P1 | ssh-access, logging, status |

No orphan flows; every use case has a priority and a testable "done when".

## Use-case gate checklist
- [x] Every use case has a priority
- [x] Every use case has a testable "done when…"
- [x] Each traces to an actor
- [x] **Human approval** (approved)
