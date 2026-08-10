# `infra/` — droplet provisioning scripts

This directory holds the **Ubuntu-side provisioning scripts** that the
`digital-ocean` CLI runs **over SSH** on the droplets it creates. They install
OS/app dependencies on a fresh box every `digital-ocean start` (droplets are
destroyed on `stop`, so state lives only on the volumes — see ADR 0001/0002).

> **Boundary discipline:** the `digital-ocean` CLI (`bin/digital-ocean`) runs
> **only on macOS**; these scripts run **only on Ubuntu** droplets. They never
> share shell code — the CLI SSHes in and invokes them.

> **Status:** not built yet. Delivered by features **F4/F5** (see
> [`../architecture/components.md`](../architecture/components.md)). This README
> is a placeholder that fixes the directory's purpose.

Planned contents (F4/F5):

| Script | Role |
|---|---|
| `preflight-local.sh` | Check Mac tools before `setup` (reports missing + `brew` fix). |
| `provision-cpu.sh` | CPU droplet: `apt` + venv + `demo/requirements.txt`. |
| `provision-gpu.sh` | GPU droplet: install Ollama, assert NVIDIA driver. |
