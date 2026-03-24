"""Experience replay buffer with JSON persistence."""

import json
import os
import random
import tempfile
from pathlib import Path
from typing import List, Tuple

from qrouter.config import DATA_DIR, REPLAY_BATCH_SIZE, REPLAY_BUFFER_SIZE

_REPLAY_PATH = DATA_DIR / "replay.json"

Experience = Tuple[str, str, float, str]  # (agent, model, reward, timestamp)


def _atomic_write(path: Path, data: str) -> None:
    fd, tmp_path = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
        os.rename(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


class ReplayBuffer:
    """Bounded circular replay buffer with JSON persistence.

    Usage pattern (one invocation = one load/save cycle):
        buf = ReplayBuffer()
        buf.load()
        buf.add((agent, model, reward, timestamp))
        batch = buf.sample()
        buf.save()
    """

    def __init__(self) -> None:
        self._entries: List[Experience] = []

    def add(self, experience: Experience) -> None:
        """Append experience, evicting oldest if at capacity."""
        self._entries.append(experience)
        if len(self._entries) > REPLAY_BUFFER_SIZE:
            self._entries = self._entries[-REPLAY_BUFFER_SIZE:]

    def sample(self, batch_size: int = REPLAY_BATCH_SIZE) -> List[Experience]:
        """Return a random sample of min(batch_size, len) entries."""
        k = min(batch_size, len(self._entries))
        if k == 0:
            return []
        return random.sample(self._entries, k)

    def load(self) -> None:
        """Load replay buffer from disk.  Creates empty buffer if missing."""
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        if _REPLAY_PATH.exists():
            try:
                raw = json.loads(_REPLAY_PATH.read_text())
                self._entries = [tuple(e) for e in raw]  # type: ignore[misc]
            except (json.JSONDecodeError, OSError, ValueError):
                self._entries = []
        else:
            self._entries = []

    def save(self) -> None:
        """Atomically persist replay buffer to disk."""
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        _atomic_write(_REPLAY_PATH, json.dumps(self._entries, indent=2))

    def __len__(self) -> int:
        return len(self._entries)
