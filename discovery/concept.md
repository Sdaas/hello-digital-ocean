# Concept Brief — DigitalOcean Demo Host (`digital-ocean` CLI + `demo` app)

> Status: DRAFT for concept-gate review
> Workspace: `/Users/sdaas/dev/hello-digital-ocean`
>
> **Rename (2026-08-10):** the control CLI is now **`digital-ocean`** (was
> referred to as `demo` in this brief); the reference chatbot is now **the
> `demo` app**, living in `demo/`. The "In your words" quote below is left
> verbatim; the AI-distillation sections use the new names.

## In your words (verbatim)

> Host a demo for an application (web UI + Python backend + LLM server). No
> security, minimal scale, this is for a demo. Two servers — a small CPU box for
> the Python backend and a GPU box for the model. Control it all from my Mac
> terminal with `setup / start / stop / destroy`. stop kills the servers but
> keeps downloaded models/data; destroy removes everything. Storage for 2–3
> models + 5–6 GB data.

> Refinements: a shell script takes a third-party credentials file from the local
> machine and puts it on the CPU server; the app reads its keys from that file.
> Need logging (folders ready on the servers). Need SSH into both boxes to debug —
> and Claude will do a lot of the debugging, so SSH/SCP access must be wired up.
> `setup` is a local-only script (checks local tools, DO access, interviews me,
> writes a local config); config is applied on `start` with health checks. It
> must still run locally too — an env var (LOCAL / DO_DEMO / DO_PROD) controls
> behavior.

> More: the README must list what the user has to do **before** `setup` (create a
> DO account, get any API keys, install local tools). Every command supports
> `--verbose` and `--help` (SDLC standard). Be careful about dependencies the
> CPU/GPU boxes may need (python, extra packages) — know what to install and
> when. All dev so far is on Mac; the DO machines are generic Linux, so ensure
> equivalent tools exist and install correctly on **both** local and DO.

> Build a small demo app in this repo first — a simple chatbot: UI + backend
> (that keeps the conversation history) + Ollama backend — so we can verify
> everything here before integrating any real application. Do not reference any
> specific downstream project in this repo's documentation. Keep third-party APIs
> generic: **if the system needs to access third-party APIs, all API keys and the
> associated configuration must be stored in a single designated credentials
> file.**

## AI distillation (approved decisions folded in)

### What we are building
This repo delivers **two things that together prove the demo-hosting machinery**:

1. **The `demo` app** (in `demo/`) — a self-contained reference chatbot used to
   exercise and verify the whole stack: a web chat UI, a Python (Flask) backend
   that keeps **conversation history**, and an **Ollama** model backend.
2. **The `digital-ocean` control CLI** — `digital-ocean setup / start / stop /
   destroy` (plus debug helpers) that provisions two droplets + persistent
   volumes and runs the `demo` app, all from the Mac.

The `demo` app is the reference workload; once the `digital-ocean` lifecycle is
proven against it, a real application can be dropped in behind the same
infrastructure unchanged.

- **CPU droplet** — Flask backend (port 5000) that keeps conversation history
  **and serves the chat UI** (single HTML file) from Flask itself.
- **GPU droplet** — **Ollama** (port 11434); model configurable (default a small
  general model, e.g. `llama3.1`).
- **Two Block Storage Volumes** — models (GPU, `/mnt/models`) and app data
  (conversation history) + logs (CPU, `/mnt/data`). Persist independently of the
  droplets.
- **Third-party APIs (generic):** the `demo` app needs none, and its
  credentials file may be empty. The infra still **provides and documents** the
  mechanism — **any keys/config an app needs live in one credentials file**,
  copied from a local file to the CPU droplet and read via an env var pointing at
  that file — but the `demo` app does not exercise it; it is verified later when a
  real app requires it.

### Actors
| Actor | Role |
|---|---|
| **Operator** (you) | Runs `setup/start/stop/destroy` + debug helpers from the Mac. |
| **Claude** | Debugs live via `ssh`/`scp` into both droplets (helper subcommands). |
| **Demo tester** | Chats with the bot in a browser while the demo is up. |
| **DigitalOcean API** | Provisions droplets/volumes; per-second billing (5-min min). |

### Command semantics (agreed)
| Command | Runs | Effect |
|---|---|---|
| **`digital-ocean local`** | Local only | Run the identical `demo` app on the Mac (`APP_ENV=LOCAL`, local Ollama, local venv from the same `demo/requirements.txt`). Local-first verification before any DO spend. `digital-ocean local down` stops it. |
| **`digital-ocean setup`** | Local only, once | Preflight local tools + DO auth + SSH key + credentials file; interview; write **local config**. No cloud resources. |
| **`digital-ocean start`** | Local → DO | Ensure volumes (create 1st time) → create droplets w/ SSH key → attach volumes → `ollama pull` (1st time only) → copy credentials file up → deploy the `demo` app (`APP_ENV=DO_DEMO`) → start Ollama + Flask → make log dirs → health-check → print URL + SSH cmds. |
| **`digital-ocean stop`** | Local → DO | Destroy CPU + GPU droplets. **Keep volumes** (models/history/logs). Only ~$15/mo volume cost remains. Repeatable start↔stop. |
| **`digital-ocean destroy`** | Local → DO | Destroy droplets **and** volumes + snapshots (confirm — deletes models/history/logs). Local config kept for a fresh re-start. |

### Key realities baked in
- **Powered-off droplets still bill in full** → `stop` destroys them; persistence
  lives on the volumes. Model downloads **once** (first `start`) and survives.
- **GPU droplets only in select regions** (NYC2 / TOR1 / ATL1 / RIC1 / AMS3) →
  **BLR1 (Bangalore) has no GPU**. Both droplets co-locate in one GPU-capable
  region so the backend↔Ollama hop stays local.
- **A volume attaches to one droplet at a time** → two volumes.

### Resolved decisions
- Frontend: **served by Flask with relative URLs** (no CORS, no IP rewrite; works
  identically LOCAL and DO_DEMO).
- Credentials: **single credentials file**, copied to **ephemeral droplet disk**
  (`/etc/app/credentials`) every `start`; never persisted on a volume. App reads
  it via an env var pointing at the file (e.g. `APP_CREDENTIALS_FILE`).
- Env switch: **`APP_ENV` ∈ {LOCAL, DO_DEMO, DO_PROD}** (DO_PROD reserved).
- Conversation history persists under `/mnt/data` → **survives stop→start** (this
  is the primary proof that the persistence story works).
- **Region: configurable, default AMS3** (nearest GPU-capable DC to India; both
  droplets co-located). BLR1 requested but unavailable for GPU.
- GPU: **RTX 4000 Ada (20 GB)** default; path to 48 GB (L40S / RTX 6000 Ada).
- Networking: **public IPs, open ports, no security** (throwaway demo only).
- Logs on **persistent volumes** so they survive `stop` and post-mortem debugging.

### Cross-cutting requirements (NFRs)
- **Prerequisites doc:** README opens with a **"Before you run `setup`"**
  checklist — create a DigitalOcean account + payment method, create an API
  token, register an SSH key, obtain any third-party keys, install local tools
  (`brew install doctl` etc.).
- **CLI standards:** every command supports `--help` and `--verbose` (per SDLC),
  plus strict-mode shell, clear errors, and idempotent re-runs.
- **Dependencies are declared, not discovered** — explicit manifests own them:
  - `infra/preflight-local.sh` → checks Mac tools (reports missing + `brew` fix).
  - `demo/requirements.txt` + `infra/provision-cpu.sh` → CPU droplet deps.
  - `infra/provision-gpu.sh` → GPU droplet deps (Ollama; assert NVIDIA driver).
  - Installed **on `start`, over SSH after boot** (idempotent; every start
    re-provisions a clean box — only volumes carry state).
- **Mac↔Linux separation:** the control script runs **only on macOS** (avoid
  GNU-only idioms; use tools present on both); provisioning/runtime scripts run
  **only on Ubuntu** droplets (`apt`); the app runs on both via `APP_ENV`.

### Non-goals (explicit)
- ❌ No security: no TLS, auth, firewall hardening, or secrets manager.
- ❌ Not production / not multi-user scale — one concurrent demo.
- ❌ No autoscaling, load balancing, HA, CI/CD, App Platform, or Kubernetes.
- ❌ The `demo` app is a **verification vehicle**, not a product — no
  polish, accounts, or persistence beyond conversation history.
- ❌ No integration with any downstream application in this repo (that happens
  later, elsewhere).
- ❌ No billing-alert automation (manual cost caution noted).

## Concept gate checklist
- [x] Non-goals written down
- [x] Every actor named
- [x] One-sentence "what we're building" agreed
- [x] **Human approval** (approved)
