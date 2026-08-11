# ADR 0008 — Backend-aware region selection

Status: Accepted · Serves: UC2 · Relates to: #17, ADR 0002

## Context
The deployment is two droplets in one region/VPC: a small web droplet and an
Ollama node (a 16 GB CPU droplet in `cpu` mode, or a GPU droplet in `gpu` mode).
A single default region (`ams3`) no longer works, because a live `doctl` sweep of
the candidate regions shows no one region can host both backends:

- **blr1 (Bangalore)** — developer's preferred, India-local. Full CPU range incl.
  the 16 GB `s-8vcpu-16gb-amd`. **No GPU at all.**
- **ams3 (Amsterdam)** — full CPU range. Cheapest GPU is an H100 at $4.41/hr.
- **tor1 (Toronto)** — has the only affordable launchable GPU (RTX 6000 Ada,
  48 GB, $1.57/hr). **No 16 GB standard droplet** (tops out at `s-4vcpu-8gb`).

The cheap RTX 4000 Ada / L40S are catalog-listed but not orderable (`regions:[]`).

## Options
1. **Single fixed region (tor1)** — one region for both; forces the CPU Ollama
   node down to 8 GB (small models only). Simple, but cripples the default path.
2. **Single fixed region (ams3)** — keeps CPU healthy but the only GPU is a
   $4.41/hr H100; ignores the blr preference and India latency.
3. **Backend-aware region** — derive region from `OLLAMA_BACKEND`: `cpu→blr1`,
   `gpu→tor1`. Each backend runs where it is both viable and cheapest.

## Comparison metric
**Cost + viability for a 1–2 user demo**, with India latency as a tiebreak.

## Decision
**Option 3** — region is a pure function of the backend: **`cpu→blr1`,
`gpu→tor1`**. An explicit `DO_REGION` env/config value still overrides. `ams3` is
dropped (dominated by blr1 for the CPU path: same price, better latency).

## Why
It gives the default (CPU) demo the cheapest, India-local home, and the opt-in GPU
demo the only affordable GPU — accepting India→Toronto latency only when a GPU is
explicitly requested. Deriving from the backend (rather than storing a region the
user must keep in sync) means switching backend can never leave a stale,
incompatible region behind.
