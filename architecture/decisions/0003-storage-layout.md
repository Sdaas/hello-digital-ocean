# ADR 0003 — Storage layout

Status: Accepted · Serves: UC2, UC3, UC4

## Context
Must persist (a) Ollama models on the GPU box and (b) conversation history + logs
on the CPU box, across `stop`. A DigitalOcean Block Storage Volume **attaches to
exactly one droplet at a time** and must be in the droplet's region.

## Options
1. **One shared volume** — impossible to mount on both droplets simultaneously;
   would force models and app data onto one box.
2. **Two volumes** — models volume on the GPU droplet (`/mnt/models`), data
   volume on the CPU droplet (`/mnt/data`). Each persists independently.
3. **Local droplet disk only** — no separate volume; destroyed with the droplet
   on `stop`, so models re-download every time. Fails the core requirement.

## Comparison metric
**Fit to the one-droplet-per-volume constraint while surviving `stop`.**

## Decision
**Option 2** — two volumes: models→GPU `/mnt/models`, data+logs→CPU `/mnt/data`.

## Why
The only layout compatible with DO's one-droplet-per-volume rule that also keeps
both the models and the app data/logs across a stop→start cycle.

## Sizing (default, configurable)
- Models volume: **50 GB** (~2 models; bump via config for more).
- Data volume: **10 GB** — holds app data + conversation history **+ logs**.
- Fixed idle cost at these sizes: 50 GB + 10 GB × $0.10/GiB/mo ≈ **$6/mo**.
