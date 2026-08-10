# CLAUDE.md — hello-digital-ocean

This project is developed with the global **agentic SDLC** (installed via
`~/.claude`). Follow that process: interview → design → test-first code →
review → ship, human-in-the-loop, effort scaled by tier.

## Project marker

- **Name:** hello-digital-ocean
- **Archetype:** cli
- **Profile (stack):** shell
- **Distribution:** none

Use this marker to select the right stack profile without re-asking.

## Repo shape (names matter)

- **Main artifact:** the **`digital-ocean`** control CLI (`bin/digital-ocean`) —
  provisions/tears down the DigitalOcean infra and runs the demo app on it
  (`digital-ocean start|stop|setup|destroy|local|ssh|logs|status`).
- **`demo/`** — the **demo app** (Flask + chat UI + Ollama client), a
  self-contained showcase that proves the `digital-ocean` CLI works end to end.
  Built in feature F2.
- **`infra/`** — Ubuntu provisioning scripts run over SSH on the droplets
  (F4/F5).

The repo is *named* `hello-digital-ocean`; the *binary* is `digital-ocean`.

## Ground rules

- Backlog lives in GitHub Issues. Trivial changes go on `main`; everything else
  gets its own branch.
- All testing and release run through `./test.sh` and `./release.sh`.
- Tests must be green before push (pre-push hook) and before merge (CI).
- The curated end-to-end design lives in `design/overview.md` — keep it current;
  record only the **key** decisions, not every one.
