"""APP_ENV configuration layer (C16) for the demo app.

One `Config` resolved from the environment. Two profiles — LOCAL (the Mac, run
by `digital-ocean local`, UC7) and DO_DEMO (the CPU droplet, UC5) — differ only
in a few defaults (bind host, data dir, credentials path). Every value is
individually overridable by an explicit environment variable, which is how
`digital-ocean start` injects the GPU's private Ollama URL (ADR 0006/0007).

Env vars:
  APP_ENV               LOCAL | DO_DEMO            (default LOCAL)
  OLLAMA_URL            base URL of the Ollama server (default localhost:11434)
  OLLAMA_MODEL          model tag                   (default llama3.2:1b)
  APP_DATA_DIR          history + logs dir          (LOCAL: demo/.localdata,
                                                     DO_DEMO: /mnt/data)
  APP_CREDENTIALS_FILE  third-party keys file       (DO_DEMO: /etc/app/credentials)
  HOST / PORT           bind address / port         (LOCAL 127.0.0.1, DO 0.0.0.0 / 5000)
  APP_DEBUG             truthy -> DEBUG-level logging
"""

import os

APP_ENV_LOCAL = "LOCAL"
APP_ENV_DO_DEMO = "DO_DEMO"

_HERE = os.path.abspath(os.path.dirname(__file__))
_TRUTHY = {"1", "true", "yes", "on"}


class Config:
    def __init__(
        self,
        *,
        app_env,
        ollama_url,
        ollama_model,
        data_dir,
        credentials_file,
        host,
        port,
        debug,
    ):
        self.app_env = app_env
        self.ollama_url = ollama_url
        self.ollama_model = ollama_model
        self.data_dir = data_dir
        self.credentials_file = credentials_file
        self.host = host
        self.port = port
        self.debug = debug

    @classmethod
    def from_env(cls, environ=None):
        env = os.environ if environ is None else environ

        app_env = env.get("APP_ENV", APP_ENV_LOCAL)
        is_do = app_env == APP_ENV_DO_DEMO

        # Profile-specific defaults (overridable individually below).
        default_data_dir = "/mnt/data" if is_do else os.path.join(_HERE, ".localdata")
        default_host = "0.0.0.0" if is_do else "127.0.0.1"
        default_creds = "/etc/app/credentials" if is_do else ""

        return cls(
            app_env=app_env,
            ollama_url=env.get("OLLAMA_URL", "http://localhost:11434").rstrip("/"),
            ollama_model=env.get("OLLAMA_MODEL", "llama3.2:1b"),
            data_dir=env.get("APP_DATA_DIR", default_data_dir),
            credentials_file=env.get("APP_CREDENTIALS_FILE", default_creds),
            host=env.get("HOST", default_host),
            port=int(env.get("PORT", "5000")),
            debug=env.get("APP_DEBUG", "").strip().lower() in _TRUTHY,
        )

    @property
    def history_path(self):
        return os.path.join(self.data_dir, "history.jsonl")

    @property
    def log_path(self):
        return os.path.join(self.data_dir, "logs", "app.log")
