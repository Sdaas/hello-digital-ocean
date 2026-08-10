"""Un-mocked Ollama boundary test (sdlc-common §3 mock-obligation).

Opt-in: runs only under `./test.sh --integration`. Self-skips when Ollama isn't
reachable or the model isn't pulled, so the pre-push hook stays non-blocking.

Locally:  ollama serve &   ollama pull llama3.2:1b
"""

import urllib.request

import pytest

pytestmark = pytest.mark.integration


def _ollama_up(base_url):
    try:
        with urllib.request.urlopen(base_url + "/api/tags", timeout=2) as resp:
            return resp.status == 200
    except Exception:
        return False


def test_real_ollama_chat_returns_text():
    from config import Config

    cfg = Config.from_env({})  # honours OLLAMA_URL / OLLAMA_MODEL if exported
    if not _ollama_up(cfg.ollama_url):
        pytest.skip(f"Ollama not reachable at {cfg.ollama_url}")

    import ollama_client

    try:
        reply = ollama_client.chat(
            [{"role": "user", "content": "Reply with the single word: pong"}],
            url=cfg.ollama_url,
            model=cfg.ollama_model,
            timeout=120,
        )
    except ollama_client.OllamaError as e:
        pytest.skip(f"Ollama error (is model {cfg.ollama_model!r} pulled?): {e}")

    assert isinstance(reply, str) and reply.strip()
