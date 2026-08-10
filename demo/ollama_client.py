"""Minimal Ollama chat client (C15), hand-rolled on the stdlib.

Keeps the demo app's only runtime dependency to Flask (ADR-ethos: fewest moving
parts). Talks to Ollama's HTTP API `/api/chat` in non-streaming mode and returns
the assistant's full reply text. Any transport/protocol failure is normalised to
`OllamaError` so the web layer can turn it into a clean 502.
"""

import json
import urllib.error
import urllib.request

DEFAULT_TIMEOUT = 120


class OllamaError(Exception):
    """Ollama was unreachable or returned an unusable response."""


def _post_json(url, payload, timeout):
    """POST a JSON body and return the parsed JSON response (a dict).

    Factored out so tests can exercise `chat()`'s request-shaping/parsing while
    the real network call is covered by the opt-in integration test.
    """
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8")
    except (urllib.error.URLError, OSError) as e:
        raise OllamaError(f"cannot reach Ollama at {url}: {e}") from e
    try:
        return json.loads(body)
    except ValueError as e:
        raise OllamaError(f"invalid JSON from Ollama: {e}") from e


def chat(messages, *, url, model, timeout=DEFAULT_TIMEOUT):
    """Send the conversation to Ollama and return the assistant reply text.

    `messages` is a list of {"role", "content"} dicts (extra keys ignored).
    """
    payload = {
        "model": model,
        "messages": [{"role": m["role"], "content": m["content"]} for m in messages],
        "stream": False,
    }
    result = _post_json(url.rstrip("/") + "/api/chat", payload, timeout)

    if isinstance(result, dict) and result.get("error"):
        raise OllamaError(str(result["error"]))
    try:
        return result["message"]["content"]
    except (KeyError, TypeError) as e:
        raise OllamaError(f"unexpected Ollama response shape: {result!r}") from e
