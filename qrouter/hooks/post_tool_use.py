"""Claude Code post_tool_use hook.

Reads a JSON event from stdin.  If the tool is an Agent invocation with a
parseable outcome, records the experience and updates the Q-table.
On any error, approves silently and exits 0.
"""

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


_APPROVE = {"decision": "approve"}


def _safe_exit(msg: str = "") -> None:
    if msg:
        print(msg, file=sys.stderr)
    print(json.dumps(_APPROVE))
    sys.exit(0)


def _parse_outcome(text: str):
    """Extract outcome string from tool output.

    Returns "done" or "blocked", or None if not parseable.
    """
    if not isinstance(text, str):
        return None

    # Specialist / post-agent contract: STATUS: done|blocked
    m = re.search(r'\bSTATUS:\s*(done|blocked)\b', text, re.IGNORECASE)
    if m:
        return m.group(1).lower()

    # Tester contract: VERDICT: PASS|FAIL
    m = re.search(r'\bVERDICT:\s*(PASS|FAIL)\b', text, re.IGNORECASE)
    if m:
        verdict = m.group(1).upper()
        return "done" if verdict == "PASS" else "blocked"

    # Committer contract: STATUS: committed|nothing_to_commit
    m = re.search(r'\bSTATUS:\s*(committed|nothing_to_commit)\b', text, re.IGNORECASE)
    if m:
        return "done"

    return None


def _get_model_from_agents_dir(agent: str) -> str:
    """Read the model: field from the agent's .md frontmatter."""
    agents_dir = os.environ.get("QROUTER_AGENTS_DIR", "./agents")
    md_path = Path(agents_dir) / f"{agent}.md"
    if not md_path.exists():
        return ""
    try:
        text = md_path.read_text()
        # Extract frontmatter between --- delimiters
        fm_match = re.match(r'\A---\n(.*?)---\n', text, re.DOTALL)
        if not fm_match:
            return ""
        fm_body = fm_match.group(1)
        m = re.search(r'^model:\s*(\S+)', fm_body, re.MULTILINE)
        if m:
            return m.group(1).strip()
    except OSError:
        pass
    return ""


def main() -> None:
    try:
        raw = sys.stdin.read()
        event = json.loads(raw)
    except Exception as exc:
        _safe_exit(f"qrouter post_tool_use: failed to parse stdin: {exc}")

    try:
        tool_name = event.get("tool_name", "")
        if tool_name != "Agent":
            print(json.dumps(_APPROVE))
            return

        tool_input = event.get("tool_input", {})
        agent = tool_input.get("subagent_type", "")
        if not agent:
            print(json.dumps(_APPROVE))
            return

        from qrouter.config import MODELS, PINNED_AGENTS

        if agent in PINNED_AGENTS:
            print(json.dumps(_APPROVE))
            return

        # Parse outcome from tool output
        tool_output = event.get("tool_response", "") or event.get("tool_output", "")
        # tool_output may be a dict with "output" key or a plain string
        if isinstance(tool_output, dict):
            tool_output = tool_output.get("output", "") or tool_output.get("text", "")

        outcome = _parse_outcome(str(tool_output))
        if outcome is None:
            # No parseable outcome — do not record
            print(json.dumps(_APPROVE))
            return

        # Determine which model was used
        model = _get_model_from_agents_dir(agent)
        if model not in MODELS:
            # Fall back to a best guess from Q-table current best
            print(
                f"qrouter post_tool_use: could not determine model for agent '{agent}', skipping record",
                file=sys.stderr,
            )
            print(json.dumps(_APPROVE))
            return

        from qrouter.config import REPLAY_BATCH_SIZE
        from qrouter.qtable import QTable
        from qrouter.replay import ReplayBuffer
        from qrouter.reward import compute_reward
        from qrouter.cli import _append_history, _ensure_initialized

        _ensure_initialized()

        reward = compute_reward(outcome, model)
        ts = datetime.now(timezone.utc).isoformat()

        buf = ReplayBuffer()
        buf.load()
        buf.add((agent, model, reward, ts))
        batch = buf.sample(REPLAY_BATCH_SIZE)
        buf.save()

        episode_captured = [0]

        def _update(qt: QTable) -> None:
            qt.update(agent, model, reward)
            for b_agent, b_model, b_reward, _ in batch:
                if b_agent != agent or b_model != model:
                    qt.update(b_agent, b_model, b_reward)
            qt.decay_epsilon()
            episode_captured[0] = qt.episode

        qt = QTable()
        success = qt.locked_load_save(_update)
        if not success:
            print(
                f"qrouter post_tool_use: lock timeout for agent '{agent}', dropping update",
                file=sys.stderr,
            )
            print(json.dumps(_APPROVE))
            return

        _append_history(agent, model, outcome, 0, reward, episode_captured[0])

        print(json.dumps(_APPROVE))

    except Exception as exc:
        _safe_exit(f"qrouter post_tool_use: unexpected error: {exc}")


if __name__ == "__main__":
    main()
