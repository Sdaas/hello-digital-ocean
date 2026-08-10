"""Shared pytest fixtures for the demo app.

The demo app is a flat, script-style package (run via `python demo/app.py`), so
tests put the demo/ directory on sys.path and import its modules directly
(`import app`, `import config`, ...).
"""

import os
import sys

import pytest

DEMO_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if DEMO_DIR not in sys.path:
    sys.path.insert(0, DEMO_DIR)


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "integration: exercises a real external boundary (Ollama); self-skips "
        "when the boundary is absent. Runs only under `./test.sh --integration`.",
    )


@pytest.fixture
def cfg(tmp_path):
    """A LOCAL config pointing history/logs at a throwaway tmp dir."""
    from config import Config

    return Config.from_env(
        {
            "APP_ENV": "LOCAL",
            "APP_DATA_DIR": str(tmp_path / "data"),
            "OLLAMA_MODEL": "test-model",
        }
    )


@pytest.fixture
def app(cfg):
    from app import create_app

    application = create_app(cfg)
    application.config.update(TESTING=True)
    return application


@pytest.fixture
def client(app):
    return app.test_client()


@pytest.fixture
def fake_reply(monkeypatch):
    """Stub the Ollama boundary; capture what the app sent it.

    Mocking this network boundary obligates the opt-in, un-mocked test in
    tests/integration/ (sdlc-common §3) — see test_ollama_real.py.
    """
    import ollama_client

    calls = {}

    def _fake(messages, *, url, model, timeout=None):
        calls["messages"] = messages
        calls["url"] = url
        calls["model"] = model
        return "canned reply"

    monkeypatch.setattr(ollama_client, "chat", _fake)
    return calls
