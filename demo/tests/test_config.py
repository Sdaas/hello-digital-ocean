"""APP_ENV config layer (C16): LOCAL vs DO_DEMO defaults, env overrides."""

import os


def test_local_defaults():
    from config import Config

    c = Config.from_env({})
    assert c.app_env == "LOCAL"
    assert c.ollama_url == "http://localhost:11434"
    assert c.ollama_model == "llama3.2:1b"
    assert c.host == "127.0.0.1"
    assert c.port == 5000
    assert c.data_dir.endswith(".localdata")


def test_do_demo_defaults():
    from config import Config

    c = Config.from_env({"APP_ENV": "DO_DEMO"})
    assert c.app_env == "DO_DEMO"
    # DO_DEMO binds publicly and persists to the mounted data volume (ADR 0003).
    assert c.host == "0.0.0.0"
    assert c.data_dir == "/mnt/data"
    assert c.credentials_file == "/etc/app/credentials"


def test_env_overrides_win_over_profile_defaults():
    from config import Config

    c = Config.from_env(
        {
            "APP_ENV": "DO_DEMO",
            "OLLAMA_URL": "http://10.0.0.5:11434",
            "OLLAMA_MODEL": "foo:latest",
            "PORT": "8080",
            "APP_DATA_DIR": "/srv/data",
            "HOST": "127.0.0.1",
        }
    )
    assert c.ollama_url == "http://10.0.0.5:11434"
    assert c.ollama_model == "foo:latest"
    assert c.port == 8080
    assert c.data_dir == "/srv/data"
    assert c.host == "127.0.0.1"


def test_derived_paths_live_under_data_dir(tmp_path):
    from config import Config

    c = Config.from_env({"APP_DATA_DIR": str(tmp_path)})
    assert c.history_path == os.path.join(str(tmp_path), "history.jsonl")
    assert c.log_path == os.path.join(str(tmp_path), "logs", "app.log")
