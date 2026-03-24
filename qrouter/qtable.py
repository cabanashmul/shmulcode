"""Q-table persistence and update logic with file-locking for concurrent access."""

import fcntl
import json
import os
import random
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, Optional, Tuple

from qrouter.config import (
    ALPHA,
    CURRENT_ASSIGNMENTS,
    DATA_DIR,
    EPSILON_DECAY,
    EPSILON_INIT,
    EPSILON_MIN,
    MODELS,
    PINNED_AGENTS,
)

_QTABLE_PATH = DATA_DIR / "qtable.json"
_CONFIG_PATH = DATA_DIR / "config.json"
_LOCK_PATH = DATA_DIR / "qtable.lock"

_FLOCK_BACKOFF_START = 0.1   # seconds
_FLOCK_BACKOFF_CAP = 2.0     # seconds
_FLOCK_TIMEOUT = 7.0         # seconds


def _ensure_data_dir() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)


def _atomic_write(path: Path, data: str) -> None:
    """Write data atomically using a temp file and os.rename."""
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


def _acquire_flock(lock_file) -> bool:
    """Try to acquire an exclusive flock with exponential backoff + jitter.

    Returns True on success, False if the 7-second deadline is exceeded.
    """
    deadline = time.monotonic() + _FLOCK_TIMEOUT
    delay = _FLOCK_BACKOFF_START
    while True:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            jitter = random.uniform(0, delay * 0.1)
            sleep_time = min(delay + jitter, min(_FLOCK_BACKOFF_CAP, remaining))
            time.sleep(sleep_time)
            delay = min(delay * 2, _FLOCK_BACKOFF_CAP)


def _build_priors() -> Dict[str, Dict[str, float]]:
    """Build initial Q-values: current assignment gets 0.5, others 0.0."""
    table: Dict[str, Dict[str, float]] = {}
    for agent, assigned_model in CURRENT_ASSIGNMENTS.items():
        table[agent] = {m: 0.0 for m in MODELS}
        table[agent][assigned_model] = 0.5
    return table


def _load_config() -> dict:
    if _CONFIG_PATH.exists():
        try:
            return json.loads(_CONFIG_PATH.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return {"epsilon": EPSILON_INIT, "episode": 0}


def _save_config(cfg: dict) -> None:
    _atomic_write(_CONFIG_PATH, json.dumps(cfg, indent=2))


class QTable:
    """In-memory Q-table with JSON persistence and file-level locking."""

    def __init__(self) -> None:
        self._table: Dict[str, Dict[str, float]] = {}
        self._epsilon: float = EPSILON_INIT
        self._episode: int = 0

    # ------------------------------------------------------------------
    # Public persistence API
    # ------------------------------------------------------------------

    def load(self) -> None:
        """Load Q-table from disk.  If missing, initialize with priors."""
        _ensure_data_dir()
        if _QTABLE_PATH.exists():
            try:
                self._table = json.loads(_QTABLE_PATH.read_text())
            except (json.JSONDecodeError, OSError):
                self._table = _build_priors()
        else:
            self._table = _build_priors()

        cfg = _load_config()
        self._epsilon = cfg.get("epsilon", EPSILON_INIT)
        self._episode = cfg.get("episode", 0)

    def save(self) -> None:
        """Atomically persist Q-table and config to disk."""
        _ensure_data_dir()
        _atomic_write(_QTABLE_PATH, json.dumps(self._table, indent=2))
        _save_config({"epsilon": self._epsilon, "episode": self._episode})

    # ------------------------------------------------------------------
    # Locked read-modify-write helper
    # ------------------------------------------------------------------

    def locked_load_save(self, fn) -> bool:
        """Acquire flock, call fn(self) for in-place mutations, then save.

        Returns True on success, False if lock timed out.
        """
        _ensure_data_dir()
        lock_path = _LOCK_PATH
        lock_path.touch(exist_ok=True)
        with open(lock_path, "r") as lf:
            if not _acquire_flock(lf):
                print(
                    "qrouter: lock acquisition timed out after 7s, dropping update",
                    file=sys.stderr,
                )
                return False
            try:
                self.load()
                fn(self)
                self.save()
            finally:
                fcntl.flock(lf, fcntl.LOCK_UN)
        return True

    # ------------------------------------------------------------------
    # Q-learning core
    # ------------------------------------------------------------------

    def update(self, agent: str, model: str, reward: float) -> None:
        """Update Q(agent, model) using the contextual-bandit rule (gamma=0)."""
        if agent not in self._table:
            self._table[agent] = {m: 0.0 for m in MODELS}
        q_old = self._table[agent].get(model, 0.0)
        self._table[agent][model] = q_old + ALPHA * (reward - q_old)

    def best_model(self, agent: str) -> str:
        """Return the model with the highest Q-value for the given agent."""
        if agent not in self._table:
            return CURRENT_ASSIGNMENTS.get(agent, "sonnet")
        values = self._table[agent]
        return max(MODELS, key=lambda m: values.get(m, 0.0))

    def suggest(self, agent: str, epsilon: Optional[float] = None) -> Tuple[str, bool]:
        """Epsilon-greedy model selection.

        Returns (model, was_exploration).
        """
        eps = epsilon if epsilon is not None else self._epsilon
        if random.random() < eps:
            return random.choice(MODELS), True
        return self.best_model(agent), False

    def all_values(self, agent: str) -> Dict[str, float]:
        """Return a copy of Q-values for the given agent."""
        if agent not in self._table:
            return {m: 0.0 for m in MODELS}
        return dict(self._table[agent])

    def decay_epsilon(self) -> None:
        """Apply epsilon decay and increment episode counter."""
        self._epsilon = max(EPSILON_MIN, self._epsilon * EPSILON_DECAY)
        self._episode += 1

    # ------------------------------------------------------------------
    # Properties
    # ------------------------------------------------------------------

    @property
    def epsilon(self) -> float:
        return self._epsilon

    @property
    def episode(self) -> int:
        return self._episode

    @property
    def table(self) -> Dict[str, Dict[str, float]]:
        return self._table
