# ADR 0005 — Credentials handling (generic third-party keys)

Status: Accepted · Serves: UC2 (mechanism; unexercised by the `demo` app)

## Context
Any app behind this infra may need third-party API keys. Requirement: keys live
in **one credentials file** on the local machine, copied to the CPU droplet, read
by the app via an env var. The `demo` app needs none (file may be empty).
"No security" — but the key should not linger needlessly.

## Options
1. **Ephemeral droplet disk, re-copied each `start`** — `scp` local file →
   `/etc/app/credentials`; gone when the droplet is destroyed on `stop`.
2. **On the persistent data volume** — survives `stop`; key sits on stored
   storage between demos; no re-copy needed.
3. **DO env var / user-data** — key ends up in droplet metadata + provisioning
   logs; hardest to rotate; visible in the API.
4. **Managed secrets service** — out of scope for a no-security demo.

## Comparison metric
**Secret exposure surface vs operational simplicity.**

## Decision
**Option 1** — ephemeral `/etc/app/credentials`, re-copied every `start`; app
reads it via `APP_CREDENTIALS_FILE`.

## Why
Smallest exposure surface (secret vanishes with the droplet, never on a detached
volume or in DO metadata) at trivial cost — one `scp` per start.
