# `demo/` — the demo app

This directory holds the **demo app**: a small, self-contained chatbot whose only
job is to **showcase that the `digital-ocean` control CLI works end to end**.

- **What it is:** a web chat UI + a Python (Flask) backend that keeps
  conversation history + an **Ollama** model backend.
- **Why it exists:** it is the *reference workload* the `digital-ocean` CLI
  provisions and runs. Once the lifecycle (`setup → start → stop → destroy`) is
  proven against this app, a real application can be dropped in behind the same
  infrastructure unchanged.
- **Where it runs:** identically on the Mac (`APP_ENV=LOCAL`, via
  `digital-ocean local`) and on the DigitalOcean CPU droplet (`APP_ENV=DO_DEMO`).

> **Status:** not built yet. The demo app is delivered by feature **F2** (see
> [`../architecture/components.md`](../architecture/components.md)). This README
> is a placeholder that fixes the directory's purpose and name.

Planned contents (F2): `requirements.txt`, the Flask app, and a single-file chat
UI served by Flask with relative URLs (see ADR 0004).
