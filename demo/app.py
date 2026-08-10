#!/usr/bin/env python3
"""Demo app (COMP-3): Flask backend + conversation history + Ollama chat.

Self-contained showcase that proves the `digital-ocean` control CLI works end to
end. Serves a single-page chat UI same-origin with relative URLs (ADR 0004), so
the identical code runs on the Mac (APP_ENV=LOCAL, UC7) and on the DigitalOcean
CPU droplet (APP_ENV=DO_DEMO, UC5).

Run locally:  APP_ENV=LOCAL python demo/app.py   (or via `digital-ocean local`, F3)
"""

import logging
import os
import sys
import time

from flask import Flask, jsonify, request, send_from_directory

import ollama_client
from config import Config
from history import History

STATIC_DIR = os.path.join(os.path.abspath(os.path.dirname(__file__)), "static")


def _configure_logging(cfg):
    """Leveled logging (INFO default, DEBUG via APP_DEBUG, ERROR always), ISO-8601
    UTC, to stderr AND a file on the persistent data volume (C17)."""
    level = logging.DEBUG if cfg.debug else logging.INFO
    fmt = logging.Formatter(
        "%(asctime)s %(levelname)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%SZ"
    )
    fmt.converter = time.gmtime  # UTC timestamps

    logger = logging.getLogger("demo")
    logger.setLevel(level)
    logger.handlers.clear()

    stream = logging.StreamHandler(sys.stderr)
    stream.setFormatter(fmt)
    logger.addHandler(stream)

    try:
        os.makedirs(os.path.dirname(cfg.log_path), exist_ok=True)
        file_handler = logging.FileHandler(cfg.log_path)
        file_handler.setFormatter(fmt)
        logger.addHandler(file_handler)
    except OSError as e:  # never let a missing volume stop the app from serving
        logger.error("could not open log file %s: %s", cfg.log_path, e)
    return logger


def create_app(config=None):
    cfg = config or Config.from_env()
    app = Flask(__name__, static_folder=None)
    app.config["DEMO_CONFIG"] = cfg

    log = _configure_logging(cfg)
    history = History(cfg.history_path)
    log.info(
        "demo app starting: app_env=%s model=%s ollama_url=%s data_dir=%s",
        cfg.app_env,
        cfg.ollama_model,
        cfg.ollama_url,
        cfg.data_dir,
    )

    @app.get("/")
    def index():
        return send_from_directory(STATIC_DIR, "index.html")

    @app.get("/health")
    def health():
        return jsonify(
            status="ok",
            app_env=cfg.app_env,
            model=cfg.ollama_model,
            ollama_url=cfg.ollama_url,
            ollama_reachable=_ollama_reachable(cfg.ollama_url),
        )

    @app.get("/history")
    def get_history():
        return jsonify(messages=history.load())

    @app.post("/chat")
    def chat():
        payload = request.get_json(silent=True) or {}
        message = (payload.get("message") or "").strip()
        if not message:
            return jsonify(error="message must be a non-empty string"), 400

        # Build the outgoing conversation without persisting yet, so a backend
        # failure leaves no dangling user turn in the stored history.
        conversation = history.load() + [{"role": "user", "content": message}]
        try:
            reply = ollama_client.chat(
                conversation, url=cfg.ollama_url, model=cfg.ollama_model
            )
        except ollama_client.OllamaError as e:
            log.error("chat failed: %s", e)
            return jsonify(error=f"model backend unavailable: {e}"), 502

        history.append("user", message)
        history.append("assistant", reply)
        log.info("chat turn ok (%d chars in, %d chars out)", len(message), len(reply))
        return jsonify(reply=reply)

    return app


def _ollama_reachable(base_url):
    import urllib.request

    try:
        with urllib.request.urlopen(base_url.rstrip("/") + "/api/tags", timeout=2) as r:
            return r.status == 200
    except Exception:
        return False


def main():
    cfg = Config.from_env()
    app = create_app(cfg)
    # threaded so a slow Ollama turn doesn't block /health during F7 checks.
    app.run(host=cfg.host, port=cfg.port, threaded=True)


if __name__ == "__main__":
    main()
