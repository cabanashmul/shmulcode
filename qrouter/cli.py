"""CLI entry point for qrouter."""

import argparse
import csv
import fcntl
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from qrouter.config import (
    ALPHA,
    DATA_DIR,
    EPSILON_DECAY,
    EPSILON_INIT,
    EPSILON_MIN,
    MODELS,
    PINNED_AGENTS,
    REPLAY_BATCH_SIZE,
)
from qrouter.qtable import QTable, _LOCK_PATH, _acquire_flock, _atomic_write
from qrouter.replay import ReplayBuffer
from qrouter.reward import compute_reward

_HISTORY_PATH = DATA_DIR / "history.csv"
_HISTORY_HEADER = ["timestamp", "agent", "model", "outcome", "retries", "reward", "episode"]


# ---------------------------------------------------------------------------
# Data directory bootstrap
# ---------------------------------------------------------------------------

def _ensure_initialized() -> None:
    """Create data directory and seed files on first run."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    from qrouter.qtable import (
        _CONFIG_PATH,
        _QTABLE_PATH,
        _build_priors,
        _save_config,
        _atomic_write as _aw,
    )
    from qrouter.replay import _REPLAY_PATH

    if not _QTABLE_PATH.exists():
        _aw(_QTABLE_PATH, json.dumps(_build_priors(), indent=2))
    if not _CONFIG_PATH.exists():
        _save_config({"epsilon": EPSILON_INIT, "episode": 0})
    if not _REPLAY_PATH.exists():
        _aw(_REPLAY_PATH, json.dumps([], indent=2))
    if not _HISTORY_PATH.exists():
        _atomic_write(_HISTORY_PATH, ",".join(_HISTORY_HEADER) + "\n")


# ---------------------------------------------------------------------------
# History helpers
# ---------------------------------------------------------------------------

def _append_history(agent: str, model: str, outcome: str, retries: int,
                    reward: float, episode: int) -> None:
    """Append one row to history.csv (plain append, not atomic — append is O_APPEND safe)."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).isoformat()
    row = [ts, agent, model, outcome, str(retries), f"{reward:.4f}", str(episode)]
    with open(_HISTORY_PATH, "a", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(row)


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def cmd_suggest(args) -> None:
    _ensure_initialized()

    agent = args.agent

    if agent in PINNED_AGENTS:
        model = PINNED_AGENTS[agent]
        result = {
            "model": model,
            "exploration": False,
            "q_values": {m: (0.5 if m == model else 0.0) for m in MODELS},
            "epsilon": 0.0,
            "pinned": True,
        }
        print(json.dumps(result))
        return

    qt = QTable()
    qt.load()
    model, was_exploration = qt.suggest(agent)
    result = {
        "model": model,
        "exploration": was_exploration,
        "q_values": qt.all_values(agent),
        "epsilon": round(qt.epsilon, 6),
    }
    print(json.dumps(result))


def cmd_record(args) -> None:
    _ensure_initialized()

    agent = args.agent
    model = args.model
    outcome = args.outcome
    retries = args.retries

    if model not in MODELS:
        print(f"error: unknown model '{model}'", file=sys.stderr)
        sys.exit(1)

    reward = compute_reward(outcome, model, retries)
    episode_at_record = [0]  # capture from inside closure

    buf = ReplayBuffer()
    buf.load()

    ts = datetime.now(timezone.utc).isoformat()
    buf.add((agent, model, reward, ts))
    batch = buf.sample(REPLAY_BATCH_SIZE)
    buf.save()

    def _update(qt: QTable) -> None:
        # Primary update
        qt.update(agent, model, reward)
        # Mini-batch replay updates
        for b_agent, b_model, b_reward, _ in batch:
            if b_agent != agent or b_model != model:  # avoid double-counting same experience
                qt.update(b_agent, b_model, b_reward)
        qt.decay_epsilon()
        episode_at_record[0] = qt.episode

    qt = QTable()
    success = qt.locked_load_save(_update)
    if not success:
        print("qrouter: record dropped due to lock timeout", file=sys.stderr)
        sys.exit(0)

    _append_history(agent, model, outcome, retries, reward, episode_at_record[0])

    print(json.dumps({
        "agent": agent,
        "model": model,
        "outcome": outcome,
        "retries": retries,
        "reward": round(reward, 4),
        "episode": episode_at_record[0],
    }))


def cmd_status(args) -> None:
    _ensure_initialized()

    qt = QTable()
    qt.load()

    agent_filter = getattr(args, "agent", None)

    print(f"Epsilon: {qt.epsilon:.6f}  Episode: {qt.episode}")
    print()

    agents_to_show = [agent_filter] if agent_filter else sorted(qt.table.keys())

    col_w = max((len(a) for a in agents_to_show), default=10)
    header = f"{'Agent':<{col_w}}  " + "  ".join(f"{m:>8}" for m in MODELS) + "  Best"
    print(header)
    print("-" * len(header))

    for agent in agents_to_show:
        if agent not in qt.table:
            print(f"  {agent}: no data")
            continue
        vals = qt.all_values(agent)
        best = qt.best_model(agent)
        row = f"{agent:<{col_w}}  " + "  ".join(f"{vals.get(m, 0.0):>8.4f}" for m in MODELS)
        row += f"  {best}"
        if agent in PINNED_AGENTS:
            row += f"  [PINNED={PINNED_AGENTS[agent]}]"
        print(row)

    print()
    print("Pinned agents (not in Q-table):")
    for agent, model in PINNED_AGENTS.items():
        print(f"  {agent}: {model}")


def cmd_apply(args) -> None:
    """Update agent .md files with best_model from Q-table."""
    _ensure_initialized()

    agents_dir = Path(args.agents_dir)
    if not agents_dir.exists():
        print(f"error: agents dir '{agents_dir}' not found", file=sys.stderr)
        sys.exit(1)

    _LOCK_PATH.touch(exist_ok=True)
    with open(_LOCK_PATH, "r") as lf:
        if not _acquire_flock(lf):
            print("qrouter apply: lock timeout, aborting", file=sys.stderr)
            sys.exit(1)
        try:
            qt = QTable()
            qt.load()

            for md_file in sorted(agents_dir.glob("*.md")):
                agent_name = md_file.stem
                if agent_name in PINNED_AGENTS:
                    continue  # never touch pinned agents

                text = md_file.read_text()
                new_model = qt.best_model(agent_name)

                # Only replace model: line within YAML frontmatter (between --- delimiters)
                # Pattern: find the frontmatter block and replace model: <value> within it
                def _replace_frontmatter_model(content: str, model: str) -> str:
                    """Replace the model: field in YAML frontmatter without touching anything else."""
                    # Frontmatter is between the first and second ---
                    fm_pattern = re.compile(r'\A(---\n)(.*?)(---\n)', re.DOTALL)
                    m = fm_pattern.match(content)
                    if not m:
                        return content  # no frontmatter — skip
                    pre, fm_body, post_delim = m.group(1), m.group(2), m.group(3)
                    rest = content[m.end():]
                    # Replace model: <value> line inside frontmatter only
                    new_fm = re.sub(
                        r'^(model:\s*).*$',
                        lambda x: x.group(1) + model,
                        fm_body,
                        flags=re.MULTILINE,
                    )
                    return pre + new_fm + post_delim + rest

                new_text = _replace_frontmatter_model(text, new_model)
                if new_text != text:
                    _atomic_write(md_file, new_text)
                    print(f"  {agent_name}: updated to {new_model}")
                else:
                    print(f"  {agent_name}: already {new_model} (no change)")
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def cmd_export(args) -> None:
    _ensure_initialized()

    qt = QTable()
    qt.load()

    snapshot = {
        "qtable": qt.table,
        "epsilon": qt.epsilon,
        "episode": qt.episode,
        "config": {
            "alpha": ALPHA,
            "epsilon_init": EPSILON_INIT,
            "epsilon_decay": EPSILON_DECAY,
            "epsilon_min": EPSILON_MIN,
            "models": MODELS,
            "pinned_agents": PINNED_AGENTS,
        },
    }

    output_path = Path(args.output)
    _atomic_write(output_path, json.dumps(snapshot, indent=2))
    print(f"Exported to {output_path}")


def cmd_reset(args) -> None:
    _ensure_initialized()

    from qrouter.qtable import _build_priors

    def _do_reset(qt: QTable) -> None:
        qt._table = _build_priors()
        qt._epsilon = EPSILON_INIT
        qt._episode = 0

    qt = QTable()
    success = qt.locked_load_save(_do_reset)
    if not success:
        print("qrouter reset: lock timeout", file=sys.stderr)
        sys.exit(1)
    print("Q-table reset to priors.")


def cmd_history(args) -> None:
    _ensure_initialized()

    last_n = args.last if hasattr(args, "last") and args.last else 20

    if not _HISTORY_PATH.exists():
        print("No history yet.")
        return

    with open(_HISTORY_PATH, newline="") as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    if not rows:
        print("No history yet.")
        return

    rows = rows[-last_n:]
    col_names = _HISTORY_HEADER
    col_w = {c: max(len(c), max(len(str(r.get(c, ""))) for r in rows)) for c in col_names}

    header = "  ".join(f"{c:<{col_w[c]}}" for c in col_names)
    print(header)
    print("-" * len(header))
    for row in rows:
        print("  ".join(f"{str(row.get(c, '')):<{col_w[c]}}" for c in col_names))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="qrouter",
        description="Q-learning model router for Claude Code agent types.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # suggest
    p_suggest = sub.add_parser("suggest", help="Suggest a model for an agent.")
    p_suggest.add_argument("--agent", required=True, help="Agent name")

    # record
    p_record = sub.add_parser("record", help="Record outcome and update Q-table.")
    p_record.add_argument("--agent", required=True, help="Agent name")
    p_record.add_argument("--model", required=True, choices=MODELS, help="Model used")
    p_record.add_argument("--outcome", required=True, choices=["done", "blocked"],
                          help="Outcome: done or blocked")
    p_record.add_argument("--retries", type=int, default=0, help="Number of retries (default 0)")

    # status
    p_status = sub.add_parser("status", help="Show Q-table and learning state.")
    p_status.add_argument("--agent", default=None, help="Filter to single agent")

    # apply
    p_apply = sub.add_parser("apply", help="Apply best model assignments to agent .md files.")
    p_apply.add_argument(
        "--agents-dir",
        default=str(Path(__file__).parent.parent / "agents"),
        help="Path to agents directory (default: ../agents relative to qrouter/)",
    )

    # export
    p_export = sub.add_parser("export", help="Export Q-table snapshot to JSON.")
    p_export.add_argument("--output", required=True, help="Output file path")

    # reset
    sub.add_parser("reset", help="Reset Q-table to priors.")

    # history
    p_history = sub.add_parser("history", help="Print recent history entries.")
    p_history.add_argument("--last", type=int, default=20, help="Number of recent entries (default 20)")

    args = parser.parse_args()

    dispatch = {
        "suggest": cmd_suggest,
        "record": cmd_record,
        "status": cmd_status,
        "apply": cmd_apply,
        "export": cmd_export,
        "reset": cmd_reset,
        "history": cmd_history,
    }
    dispatch[args.command](args)


if __name__ == "__main__":
    main()
