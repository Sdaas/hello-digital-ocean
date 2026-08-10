"""Chat UI + backend (C13, C15): index served same-origin, /chat round-trip,
history endpoint, validation, and Ollama-failure handling.

The Ollama network boundary is stubbed here via the `fake_reply` fixture; the
un-mocked counterpart lives in tests/integration/test_ollama_real.py.
"""


def test_index_served_with_relative_urls(client):
    r = client.get("/")
    assert r.status_code == 200
    body = r.get_data(as_text=True)
    # ADR 0004: the UI talks to its own origin via relative paths, so there must
    # be no hardcoded backend host anywhere in the page.
    assert "/chat" in body
    assert "http://" not in body
    assert "https://" not in body


def test_chat_happy_path_persists_and_calls_ollama(client, fake_reply, cfg):
    r = client.post("/chat", json={"message": "hi there"})
    assert r.status_code == 200
    assert r.get_json()["reply"] == "canned reply"

    from history import History

    msgs = History(cfg.history_path).load()
    assert [m["role"] for m in msgs] == ["user", "assistant"]
    assert msgs[1]["content"] == "canned reply"

    # The full conversation (including the just-added user turn) went to Ollama,
    # with the configured model.
    assert fake_reply["messages"][-1]["content"] == "hi there"
    assert fake_reply["model"] == "test-model"


def test_history_endpoint_returns_prior_turns(client, fake_reply):
    client.post("/chat", json={"message": "one"})
    r = client.get("/history")
    assert r.status_code == 200
    msgs = r.get_json()["messages"]
    assert msgs[0]["content"] == "one"


def test_empty_message_rejected(client, fake_reply):
    r = client.post("/chat", json={"message": "   "})
    assert r.status_code == 400


def test_missing_message_rejected(client, fake_reply):
    r = client.post("/chat", json={})
    assert r.status_code == 400


def test_ollama_failure_returns_502(client, monkeypatch):
    import ollama_client

    def boom(*args, **kwargs):
        raise ollama_client.OllamaError("connection refused")

    monkeypatch.setattr(ollama_client, "chat", boom)

    r = client.post("/chat", json={"message": "hi"})
    assert r.status_code == 502
    assert "error" in r.get_json()
