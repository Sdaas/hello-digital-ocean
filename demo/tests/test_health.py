"""Health endpoint (used by `digital-ocean start` health checks, F7)."""


def test_health_ok(client):
    r = client.get("/health")
    assert r.status_code == 200
    j = r.get_json()
    assert j["status"] == "ok"
    assert j["app_env"] == "LOCAL"
    assert j["model"] == "test-model"
