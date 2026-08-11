# PROGRESS — DigitalOcean Demo Host (`digital-ocean` CLI + `demo` app)

> **Rename (2026-08-10):** the control CLI is now **`digital-ocean`** (was
> `demo`); the reference chatbot is now **the `demo` app** in `demo/`.

## Phase status
- [x] `/sdlc-discovery` — concept + use cases (UC1–UC7) **approved**
- [x] `/sdlc-architecture` — overview + 7 ADRs + backlog **approved**
- [x] `/sdlc-newproject` — repo scaffolded, first commit pushed, backlog seeded **done** (2026-08-10)
- [~] `/sdlc-feature` — build backlog: **F2 (#1)–F7 (#6) done** (F2–F4 2026-08-10; F5–F7 2026-08-11).
  F7 code merged (PR #15); its **billable live VERIFY is deferred** (see Follow-ups). **Next up: #18 (+#19).**

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
| F2 | #1 | `demo` app (Flask+history+Ollama+UI+`APP_ENV`) | P0 | F1 | **done** |
| F3 | #2 | `digital-ocean local` — run on the Mac | P0 | F1,F2 | **done** |
| F4 | #3 | `digital-ocean setup` — preflight + interview + config | P0 | F1 | **done** |
| F5 | #4 | Provisioning scripts (Ubuntu) | P0 | F2 | **done** |
| F6 | #5 | DO resources (volumes, droplets, VPC) | P0 | F4 | **done** |
| F7 | #6 | `digital-ocean start` orchestration (end-to-end) | P0 | F5,F6,F2 | **done** (merged; live VERIFY deferred → #19/#18/#17) |
| F8 | #7 | `digital-ocean stop` + `digital-ocean destroy` | P0 | F6 | todo |
| F9 | #8 | Debug helpers (`ssh`/`logs`/`status`) | P1 | F6 | todo |
| F10 | #9 | Docs (README prerequisites + usage) | P1 | F7 | todo |

## Follow-ups & execution sequence (decided 2026-08-11, after F7 merge)
GPU investigation (live `doctl`): the cheap RTX 4000 Ada / L40S are **not orderable**
(`available:true` but `regions:[]`); cheapest **launchable** GPU is **RTX 6000 Ada
(48 GB, $1.57/hr, `tor1` only)**; ams3 has only H100 ($4.41/hr). Default backend is
now **CPU** (`OLLAMA_BACKEND` unset → cpu), so the default demo needs **no GPU**.

Recommended order:
1. **#19** — `start`: make DO firewall **optional** + bind Ollama to the **private VPC IP**
   (satisfies ADR-0007 without a firewall) → `start` runs on the **current token**, no new
   API token needed. **#16 becomes non-blocking.**
2. **#18** — optional **CPU-based Ollama backend** (default), dedicated node; `OLLAMA_BACKEND=gpu|cpu`.
   *Do #19 + #18 together in one `/sdlc-feature`* (both touch Ollama exposure/addressing). This is
   the **first real live VERIFY** of F5+F6+F7 — on CPU, cents/hr.
3. **#17** — GPU backend: install NVIDIA driver in `provision-gpu.sh`, retarget defaults to
   **RTX 6000 Ada / tor1 / plain `ubuntu-22-04-x64`**; update cost model + ADR. Live-VERIFY GPU path.
4. **#7 (F8)** stop/destroy → **#8 (F9)** debug helpers → **#9 (F10)** docs (needs final costs).
5. **#16** — DO firewalls + firewall-scoped token: defense-in-depth, whenever. **Not blocking.**

## Locked decisions (see ADRs)
- stop = destroy droplets, keep 2 volumes; destroy = also volumes (0001)
- SSH-provision after boot, idempotent (0002)
- 2 volumes: models 50 GB → GPU `/mnt/models`, data+logs 10 GB → CPU `/mnt/data` (0003)
- Flask serves UI, relative URLs (0004)
- creds ephemeral `/etc/app/credentials`, re-copied each start (0005)
- new public IP per start, print URL (0006)
- private VPC CPU↔GPU, Ollama off public net (0007)
- region configurable; **default retargeting AMS3 → `tor1`** and **GPU → RTX 6000 Ada** (`gpu-6000adax1-48gb`, only orderable cheap GPU) via #17; model configurable via `OLLAMA_MODEL` (demo default **llama3.2:1b**, F2); `APP_ENV` = LOCAL/DO_DEMO
- **Ollama backend selectable** (#18): `OLLAMA_BACKEND=gpu|cpu`, **default cpu**; dedicated Ollama node either way (GPU vs CPU droplet) — enables GPU-vs-CPU cost/perf benchmarking (manual)
- Ollama isolation: prefer **private-VPC-IP binding** over a DO firewall (#19) so ADR-0007 holds without firewall token scope

## Cost
Fixed ~$6/mo (volumes) + variable compute while running. Original ~$0.80/hr GPU
assumption is **superseded**: cheapest launchable GPU is RTX 6000 Ada **~$1.57/hr**
(tor1); the **default CPU backend** (#18) runs Ollama on a CPU droplet for cents/hr.
Final numbers land with #17/#18. Always `stop` after a demo.

## Handoff note (updated 2026-08-11, F7 merged)
F2–F7 built and merged. **Do `/sdlc-feature #18` next (with #19 folded in)** — see the
Follow-ups section above for the full sequence and rationale. Key context for the next
session:
- **Run on the current token:** #19 makes the DO firewall optional and binds Ollama to
  the private VPC IP, so `start` no longer needs firewall scope (#16 deferred).
- **Default is CPU** (`OLLAMA_BACKEND` unset → cpu): the default demo needs no GPU.
- **GPU path (#17):** only orderable cheap GPU is RTX 6000 Ada in **tor1**; boot plain
  `ubuntu-22-04-x64` and **install the NVIDIA driver** in `provision-gpu.sh` (no AI/ML image).
- F7 `start` reuses F6 `ensure_*` helpers via `DO_SOURCE_ONLY=1`; `.do/state` now also
  carries firewall IDs. `doctl` authed locally with a token **without** firewall scope.
- **F7 live VERIFY still owed** (deferred from F5/F6 too): first real end-to-end run happens
  during #18/#19 (CPU, cheap), then #17 (GPU).
