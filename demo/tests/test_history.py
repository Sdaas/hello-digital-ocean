"""Conversation history persistence (C14): JSONL append/load, restart survival."""


def test_append_and_load_in_order(tmp_path):
    from history import History

    h = History(str(tmp_path / "history.jsonl"))
    h.append("user", "hi")
    h.append("assistant", "hello")

    msgs = h.load()
    assert [m["role"] for m in msgs] == ["user", "assistant"]
    assert msgs[0]["content"] == "hi"
    assert "ts" in msgs[0]


def test_persists_across_instances(tmp_path):
    """A fresh History over the same file sees prior turns (survives restart)."""
    from history import History

    path = str(tmp_path / "history.jsonl")
    History(path).append("user", "remember me")

    reloaded = History(path).load()
    assert reloaded[-1]["content"] == "remember me"


def test_missing_file_loads_empty(tmp_path):
    from history import History

    assert History(str(tmp_path / "does-not-exist.jsonl")).load() == []


def test_malformed_lines_are_skipped(tmp_path):
    from history import History

    path = tmp_path / "history.jsonl"
    path.write_text(
        '{"role": "user", "content": "ok", "ts": "2026-08-10T00:00:00Z"}\n'
        "not valid json\n"
        '{"missing": "role and content"}\n'
    )
    msgs = History(str(path)).load()
    assert len(msgs) == 1
    assert msgs[0]["content"] == "ok"
