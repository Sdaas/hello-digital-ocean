# `infra/` — droplet provisioning scripts

The **Ubuntu-side provisioning scripts** that the `digital-ocean` CLI runs
**over SSH** on the droplets it creates. They install OS/app dependencies on a
fresh box every `digital-ocean start` — droplets are destroyed on `stop`, so
state lives only on the volumes (ADR 0001/0002).

> **Boundary discipline:** the `digital-ocean` CLI (`bin/digital-ocean`) runs
> **only on macOS**; these scripts run **only on Ubuntu** droplets, as **root**.
> They never share shell code — the CLI SSHes in and invokes them.

## Scripts (built in F5)

| Script | Runs on | What it does |
|---|---|---|
| `provision-cpu.sh` | CPU droplet | apt `python3`/`venv`/`pip` → mount the **data** volume at `/mnt/data` → create the log dir → build the venv and `pip install -r demo/requirements.txt`. |
| `provision-gpu.sh` | GPU droplet | **assert** the NVIDIA driver (`nvidia-smi`) → mount the **models** volume at `/mnt/models` → install Ollama → point it at the volume + VPC via a systemd drop-in. |

Both are **idempotent** (re-running skips completed work) and safe to re-run
while debugging (ADR 0002). Neither deploys the app, copies credentials, pulls a
model, or configures a firewall — that is the CLI's job in **F6/F7**.

### What they deliberately do NOT do (F5 scope)
- **No driver install.** `provision-gpu.sh` *asserts* `nvidia-smi` works (DO's
  AI/ML-ready image ships the driver); it polls up to `NVIDIA_WAIT_SECS` because
  the driver can be finalized by cloud-init at first boot.
- **No model pull** (`ollama pull` is C8/F7) and **no firewall** (F6/F7).
- **Never reformats** a volume that already has a filesystem — models,
  conversation history, and logs persist across a `stop → start` (ADR 0003).

## Configuration (environment variables)

Both scripts are configured entirely by env vars, which F7 exports over SSH.
Each has a sensible default from the ADRs; run either with `--help` for the full
list. The most relevant:

**`provision-cpu.sh`**

| Var | Default | Meaning |
|---|---|---|
| `APP_DIR` | `/opt/app` | where F7 places the app |
| `REQUIREMENTS_FILE` | `$APP_DIR/demo/requirements.txt` | `pip install -r` target |
| `DATA_MOUNT` | `/mnt/data` | data volume mountpoint (+ `$DATA_MOUNT/logs`) |
| `DATA_VOLUME_NAME` | *(unset)* | DO volume name → derives the block device |
| `DATA_DEVICE` | derived from `DATA_VOLUME_NAME` | block device to format-if-empty + mount |

**`provision-gpu.sh`**

| Var | Default | Meaning |
|---|---|---|
| `MODELS_MOUNT` | `/mnt/models` | models volume mountpoint |
| `MODELS_VOLUME_NAME` / `MODELS_DEVICE` | *(unset)* / derived | the models block device |
| `NVIDIA_WAIT_SECS` | `120` | how long to poll `nvidia-smi` before failing |
| `OLLAMA_HOST` | `0.0.0.0:11434` | Ollama bind address (reachable over the VPC, ADR 0007) |

Volumes are mounted **by device-path** using DigitalOcean's recommended
`/etc/fstab` line: `… ext4 defaults,nofail,discard,noatime 0 2`.

## Testing

- **Fast/hermetic** (`./test.sh`): `tests/provision-cpu.bats` and
  `tests/provision-gpu.bats` run on macOS with every Ubuntu boundary
  (`apt`, `mkfs`/`mount`, `nvidia-smi`, `curl`, `systemctl`) PATH-shimmed.
- **Un-mocked** (`./test.sh --integration`): `tests/integration/provision.bats`
  runs each script in a real `ubuntu:22.04` **Docker** container — real apt +
  venv + `pip install Flask`, and the real "no GPU → assert fails" path. It
  **self-skips** when Docker is not available. (The volume-mount *positive* path
  and a real GPU are exercised on an actual droplet in F7.)

  Requires the Docker daemon running:
  ```sh
  ./test.sh --integration
  ```
