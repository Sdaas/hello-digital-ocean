# ADR 0004 — Frontend delivery & backend addressing

Status: Accepted · Serves: UC5, UC7

## Context
A browser UI must reach the backend both locally (`APP_ENV=LOCAL`) and on DO
(`APP_ENV=DO_DEMO`), where the backend's public IP changes every `start`
(ADR 0006). Hardcoding a backend URL would break on every start and locally.

## Options
1. **Flask serves the HTML; UI uses relative URLs** — one origin, no CORS, no
   IP knowledge in the frontend; identical LOCAL and DO.
2. **Static HTML + rewrite the URL on `start`** — string-replace the backend IP
   into the HTML each start. Hacky, re-run every start, still cross-origin.
3. **Injected `config.js` with `window.BACKEND_URL`** — start writes the backend
   URL; frontend reads it. One indirection + CORS handling.

## Comparison metric
**Number of moving parts across LOCAL and DO (incl. CORS + per-start work).**

| Option | CORS | Per-start work | Works LOCAL unchanged |
|---|---|---|---|
| **1** | none | none | yes |
| 2 | yes | rewrite | no (localhost) |
| 3 | yes | write config | needs config |

## Decision
**Option 1** — Flask serves `index.html`; the UI calls relative paths
(`/chat`, `/health`). UI URL == backend URL.

## Why
Same-origin kills CORS and the changing-IP problem entirely and runs identically
on the Mac and on DO — fewest moving parts.
