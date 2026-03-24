"""Claude Code pre_tool_use hook.

Reads a JSON event from stdin.  If the tool is an Agent invocation, emits a
Q-ROUTER system message recommending a model.  On any error, approves silently.
"""

import json
import sys


_APPROVE = {"decision": "approve"}


def _safe_exit(msg: str = "") -> None:
    if msg:
        print(msg, file=sys.stderr)
    print(json.dumps(_APPROVE))
    sys.exit(0)


def main() -> None:
    try:
        raw = sys.stdin.read()
        event = json.loads(raw)
    except Exception as exc:
        _safe_exit(f"qrouter pre_tool_use: failed to parse stdin: {exc}")

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
        from qrouter.qtable import QTable

        if agent in PINNED_AGENTS:
            model = PINNED_AGENTS[agent]
            msg = (
                f'Q-ROUTER: recommend model="{model}" for agent="{agent}" '
                f"(pinned, ε=0.00)"
            )
            print(json.dumps({"decision": "approve", "systemMessage": msg}))
            return

        qt = QTable()
        try:
            qt.load()
        except Exception as exc:
            _safe_exit(f"qrouter pre_tool_use: Q-table load failed: {exc}")

        model, was_exploration = qt.suggest(agent)
        mode = "exploration" if was_exploration else "exploitation"
        q_vals = qt.all_values(agent)
        q_best = q_vals.get(model, 0.0)
        msg = (
            f'Q-ROUTER: recommend model="{model}" for agent="{agent}" '
            f"({mode}, Q={q_best:.2f}, ε={qt.epsilon:.2f})"
        )
        print(json.dumps({"decision": "approve", "systemMessage": msg}))

    except Exception as exc:
        _safe_exit(f"qrouter pre_tool_use: unexpected error: {exc}")


if __name__ == "__main__":
    main()
