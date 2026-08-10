# PROGRESS — DigitalOcean Demo Host (`digital-ocean` CLI + `demo` app)

> **Rename (2026-08-10):** the control CLI is now **`digital-ocean`** (was
> `demo`); the reference chatbot is now **the `demo` app** in `demo/`.

## Phase status
- [x] `/sdlc-discovery` — concept + use cases (UC1–UC7) **approved**
- [x] `/sdlc-architecture` — overview + 7 ADRs + backlog **approved**
- [x] `/sdlc-newproject` — repo scaffolded, first commit pushed, backlog seeded **done** (2026-08-10)
- [ ] `/sdlc-feature` — build backlog, **next up: F2 (#1)**

Repo: https://github.com/Sdaas/hello-digital-ocean (public, MIT).

## Artifacts
- `discovery/concept.md`, `discovery/use-cases.md`
- `architecture/overview.md` (capability map, components, container diagram, cost)
- `architecture/decisions/0001–0007`
- `architecture/components.md` (feature backlog)

## Feature backlog (build order)
| ID | Issue | Feature | Prio | Depends | Status |
|---|---|---|---|---|---|
| F1 | — | Repo scaffold + `digital-ocean` CLI skeleton | P0 | — | **done** |
| F2 | #1 | `demo` app (Flask+history+Ollama+UI+`APP_ENV`) | P0 | F1 | todo |
| F3 | #2 | `digital-ocean local` — run on the Mac | P0 | F1,F2 | todo |
| F4 | #3 | `digital-ocean setup` — preflight + interview + config | P0 | F1 | todo |
| F5 | #4 | Provisioning scripts (Ubuntu) | P0 | F2 | todo |
| F6 | #5 | DO resources (volumes, droplets, VPC) | P0 | F4 | todo |
| F7 | #6 | `digital-ocean start` orchestration (end-to-end) | P0 | F5,F6,F2 | todo |
| F8 | #7 | `digital-ocean stop` + `digital-ocean destroy` | P0 | F6 | todo |
| F9 | #8 | Debug helpers (`ssh`/`logs`/`status`) | P1 | F6 | todo |
| F10 | #9 | Docs (README prerequisites + usage) | P1 | F7 | todo |

## Locked decisions (see ADRs)
- stop = destroy droplets, keep 2 volumes; destroy = also volumes (0001)
- SSH-provision after boot, idempotent (0002)
- 2 volumes: models 50 GB → GPU `/mnt/models`, data+logs 10 GB → CPU `/mnt/data` (0003)
- Flask serves UI, relative URLs (0004)
- creds ephemeral `/etc/app/credentials`, re-copied each start (0005)
- new public IP per start, print URL (0006)
- private VPC CPU↔GPU, Ollama off public net (0007)
- region configurable, default AMS3; GPU RTX 4000 Ada default; model configurable (Ollama, default llama3.1); `APP_ENV` = LOCAL/DO_DEMO/DO_PROD

## Cost
Fixed ~$6/mo (volumes) + ~$0.80/hr while running. Always `stop` after a demo.

## Handoff note
Backlog seeded as GitHub Issues **#1–#9** (F2–F10) with `Depends on:` links —
see https://github.com/Sdaas/hello-digital-ocean/issues. Build order is
local-first then cloud bottom-up: F2 (#1) → F3 (#2) → F4 (#3) → F5 (#4) →
F6 (#5) → F7 (#6) → F8 (#7), then P1 F9 (#8), F10 (#9). Start the next
capability with `/sdlc-feature #1`.
