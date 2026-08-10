# `demo/` — the demo app

The **demo app**: a small, self-contained chatbot whose only job is to **showcase
that the `digital-ocean` control CLI works end to end**. It is the *reference
workload* the CLI provisions and runs — once the lifecycle
(`setup → start → stop → destroy`) is proven against it, a real application can be
dropped in behind the same infrastructure unchanged.

- **What it is:** a single-page web chat UI + a Python (Flask) backend that keeps
  conversation history + an **Ollama** model backend.
- **Where it runs:** identically on the Mac (`APP_ENV=LOCAL`, via
  `digital-ocean local`, UC7) and on the DigitalOcean CPU droplet
  (`APP_ENV=DO_DEMO`, UC5). The UI talks to its own origin via **relative URLs**
  (ADR 0004), so the same code runs in both places with no rewrite.

## Layout

| File | Role |
|---|---|
| `app.py` | Flask app factory + routes (`/`, `/health`, `/history`, `/chat`) |
| `config.py` | `APP_ENV` config layer — LOCAL vs DO_DEMO defaults (C16) |
| `history.py` | Conversation history: JSONL append/load (C14) |
| `ollama_client.py` | Minimal Ollama `/api/chat` client on the stdlib (C15) |
| `static/index.html` | Single-file chat UI (vanilla JS, relative fetch) |
| `requirements.txt` | Runtime deps — **Flask only** |
| `requirements-dev.txt` | Dev/test deps — pytest |
| `tests/` | pytest suite (`tests/integration/` = opt-in real-Ollama test) |

## Configuration (`APP_ENV` layer)

Every value is overridable by an environment variable; the profile only changes a
few defaults. This is how `digital-ocean start` injects the GPU's private Ollama
URL at deploy time.

| Var | LOCAL default | DO_DEMO default |
|---|---|---|
| `APP_ENV` | `LOCAL` | `DO_DEMO` |
| `OLLAMA_URL` | `http://localhost:11434` | GPU private IP (injected) |
| `OLLAMA_MODEL` | `llama3.2:1b` | `llama3.2:1b` |
| `APP_DATA_DIR` | `demo/.localdata` | `/mnt/data` |
| `APP_CREDENTIALS_FILE` | *(unset)* | `/etc/app/credentials` |
| `HOST` / `PORT` | `127.0.0.1` / `5000` | `0.0.0.0` / `5000` |

The `demo` app needs no third-party credentials (the file may be empty/absent).

## Run it locally

The supported entry point is `digital-ocean local` (feature F3). To run the app
directly for development:

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install -r demo/requirements.txt
ollama serve &            # if not already running
ollama pull llama3.2:1b   # once
APP_ENV=LOCAL python3 demo/app.py
# open http://127.0.0.1:5000
```

## Tests

Run via the repo's single entry point (never pytest ad hoc in CI):

```sh
./test.sh                 # fast lane — mocked Ollama boundary
./test.sh --integration   # also the un-mocked real-Ollama test (self-skips if Ollama is down)
```

The fast lane mocks the Ollama network boundary; the mock obligates the opt-in
`tests/integration/test_ollama_real.py`, which exercises a real Ollama and
self-skips when it isn't reachable.
