"""Conversation history persistence (C14).

A single shared conversation stored as JSON Lines — one {role, content, ts}
object per line — under the data dir (`/mnt/data` on DO, ADR 0003; a local path
under LOCAL). Append-per-turn so the history survives a process/droplet restart;
malformed lines are skipped defensively so a partial write can't wedge the app.
"""

import json
import os
from datetime import datetime, timezone


def _now_iso():
    # ISO-8601 UTC, matching the repo's logging convention (design/overview.md).
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class History:
    def __init__(self, path):
        self.path = path

    def append(self, role, content):
        """Append one turn and return the stored record."""
        record = {"role": role, "content": content, "ts": _now_iso()}
        os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
        return record

    def load(self):
        """Return all turns as a list of dicts; [] if the file is absent."""
        if not os.path.exists(self.path):
            return []
        messages = []
        with open(self.path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue  # skip a malformed/partial line
                if isinstance(obj, dict) and "role" in obj and "content" in obj:
                    messages.append(obj)
        return messages
