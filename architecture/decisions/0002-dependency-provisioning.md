# ADR 0002 — Dependency provisioning mechanism

Status: Accepted · Serves: UC2

## Context
Because `stop` destroys droplets (ADR 0001), every `start` must reinstall OS/app
deps on fresh droplets. Deps are declared in `demo/requirements.txt`,
`provision-cpu.sh`, `provision-gpu.sh`. Question: how/when to run them. Claude
and the operator will iterate and debug this step frequently.

## Options
1. **cloud-init / user-data** — pass a script at droplet-create; runs on first
   boot. Declarative, but output is hidden, hard to watch/re-run, slow to debug.
2. **SSH-provision after boot** — create droplet, wait for SSH, run idempotent
   `provision-*.sh` over SSH. Live output, re-runnable, easy to debug.
3. **Pre-baked custom image (snapshot)** — bake deps into an image; fast boot,
   but image drifts, must be rebuilt on any dep change, extra snapshot cost.
4. **Config-mgmt tool (Ansible)** — powerful/idempotent, but heavy dependency and
   ceremony for a two-box demo.

## Comparison metric
**Time-to-diagnose a failed provisioning step (debuggability), for a demo we'll
iterate on.**

## Decision
**Option 2** — idempotent provisioning over SSH after boot.

## Why
Maximizes debuggability and iteration speed (live output, re-run a single step)
with no extra tooling — exactly what a demo we actively debug needs; a custom
image can be added later purely to speed boots if provisioning stabilizes.

## Amendment (#17, 2026-08-11) — the GPU driver is now a provisioned dependency
The original scope assumed the GPU droplet boots a DO **AI/ML image that ships the
NVIDIA driver**, so `provision-gpu.sh` only *asserted* `nvidia-smi`. That no longer
holds: the only affordable launchable GPU (RTX 6000 Ada, tor1 — see ADR 0008) has
**no public base image**; the sole GPU base image is H100-flavored. So the GPU node
now boots a **plain `ubuntu-22-04-x64` image**, and `provision-gpu.sh` **installs
the NVIDIA kernel driver itself** (via `ubuntu-drivers`) before the assertion. This
is fully consistent with the Option 2 decision above — the driver simply becomes
one more idempotent, SSH-provisioned dependency. The assertion is retained as the
post-install health gate.
