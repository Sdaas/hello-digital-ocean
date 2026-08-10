# ADR 0001 — Persistence & pause strategy

Status: Accepted · Serves: UC2, UC3, UC4

## Context
`stop` must halt compute cost between demos **without** re-downloading models
(2–3 models + history/logs must survive). DigitalOcean bills powered-off droplets
in full — so "power off" saves nothing.

## Options
1. **Keep droplets running** — simplest, but pays full compute 24/7.
2. **Power off droplets** — still billed in full for CPU/RAM/IP. No saving.
3. **Destroy droplets, keep Block Storage Volumes** — compute cost → $0 between
   demos; models/history persist on volumes; `start` recreates + reattaches.
4. **Snapshot droplet, destroy, restore from snapshot** — preserves the whole
   box image; snapshots bill ~$0.06/GiB/mo; restore is slower and image drifts.

## Comparison metric
**Idle $/month while preserving models + speed/cleanliness of resume.**

| Option | Idle cost | Resume | Cleanliness |
|---|---|---|---|
| 1 | full (~$550/mo GPU) | instant | drifts |
| 2 | full | instant | drifts |
| **3** | **~$15/mo (volumes)** | mins (re-provision) | **clean each start** |
| 4 | volumes + snapshots | mins | image drift |

## Decision
**Option 3** — `stop` destroys both droplets and keeps two volumes; `start`
recreates and reattaches; `destroy` removes volumes + snapshots too.

## Why
Only option that drops idle cost to near-zero while guaranteeing the model is
never re-downloaded, and re-provisioning from manifests gives a clean box every
start (state lives only on volumes).
