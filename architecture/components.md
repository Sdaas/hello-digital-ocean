# Feature Backlog — DigitalOcean Demo Host (`digital-ocean` CLI + `demo` app)

> Traces to: `discovery/use-cases.md`, `architecture/overview.md`
> Status: DRAFT for backlog-gate review
>
> **Rename (2026-08-10):** control CLI `demo` → **`digital-ocean`**; reference
> chatbot → **the `demo` app** (`demo/`).

Each feature is sized for one `/sdlc-feature` run, traced to use-case IDs, and
sequenced by dependency + deferral (local-first, core before peripheral).

## Backlog

| ID | Feature | Serves (UC) | Caps | Component | Depends on | Prio |
|---|---|---|---|---|---|---|
| **F1** | Repo scaffold + CLI skeleton (`digital-ocean` dispatch, `--help/--verbose`, strict mode, config/state file schema, README prereq stub, `.gitignore`) | UC1 (enabler for all) | C1, C4 | 1,4,5 | — | P0 |
| **F2** | `demo` app (Flask backend + conversation history + Ollama client + chat UI relative URLs + `APP_ENV` layer + `demo/requirements.txt`) | UC5, UC7 | C13–C16 | 3 | F1 | P0 |
| **F3** | `digital-ocean local` — run the `demo` app on the Mac (venv from `demo/requirements.txt`, assert local Ollama, `APP_ENV=LOCAL`, open browser, `digital-ocean local down`) | UC7 | C19 | 1 | F1, F2 | P0 |
| **F4** | `digital-ocean setup` — preflight (tools, DO auth, SSH key, creds file) + interview + write local config | UC1 | C2, C3 | 1,4 | F1 | P0 |
| **F5** | Provisioning scripts (`provision-cpu.sh`: apt+venv+pip; `provision-gpu.sh`: Ollama install, assert NVIDIA driver; mounts, log dirs) | UC2 | C7, C17 | 2 | F2 | P0 |
| **F6** | DO resource provisioning (doctl: create/attach 2 volumes, create CPU+GPU droplets w/ SSH key + VPC, record state) | UC2 | C5, C6 | 1 | F4 | P0 |
| **F7** | `digital-ocean start` orchestration (ensure volumes → droplets → run F5 provisioning → `ollama pull` → scp creds → deploy F2 `demo` app `APP_ENV=DO_DEMO` → start services → health checks → print URL + SSH) | UC2, UC5 | C8–C11 | 1 | F5, F6, F2 | P0 |
| **F8** | `digital-ocean stop` + `digital-ocean destroy` (stop: destroy droplets keep volumes; destroy: +volumes+snapshots, confirm) | UC3, UC4 | C12 | 1 | F6 | P0 |
| **F9** | Debug helpers (`digital-ocean ssh|logs|status cpu|gpu`, non-interactive host-key handling) | UC6 | C18 | 1 | F6 | P1 |
| **F10** | Docs — README prerequisites checklist + full command reference + cost note + Mac/Linux notes | UC1 (NFR) | — | 5 | F7 | P1 |

## Sequencing rationale
- **Local-first (F1→F2→F3).** Prove the `demo` app and its dependency manifests
  run on the Mac before provisioning any paid cloud — this is the cheapest place to
  find dependency/parity bugs, and satisfies the user's explicit "get it running
  locally, then deploy" requirement (UC7).
- **Cloud path bottom-up (F4→F5→F6→F7).** Config first (nothing provisions without
  it), then the Linux provisioning scripts, then DO resources, then the `start`
  orchestration that ties them together. `start` (F7) is deliberately last of the
  core four because it depends on all three below it.
- **Teardown after create (F8).** `stop`/`destroy` need resources to exist; built
  right after F6 so the create/destroy loop can be exercised together.
- **Peripheral last (F9, F10).** Debug helpers and full docs are P1 — valuable but
  not on the critical path to a working demo; deferred so core lands first. (The
  README *prerequisites* stub ships in F1; the full doc is F10.)

## Dependency graph
```
F1 ──┬─▶ F2 ──┬─▶ F3
     │        └─▶ F5 ──┐
     └─▶ F4 ──▶ F6 ──┬─┴─▶ F7 ──▶ F10
                     ├─▶ F8
                     └─▶ F9
```

## Backlog gate checklist
- [x] Every feature traces to use-case IDs
- [x] Sequenced by dependency + deferral; rationale written
- [x] No floating features; core (P0) before peripheral (P1)
- [x] **Human approval** (approved)
