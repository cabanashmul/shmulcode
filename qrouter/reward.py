from qrouter.config import COST_WEIGHT


def compute_reward(outcome: str, model: str, retries: int = 0) -> float:
    """Compute reward for a completed agent invocation.

    Reward bounds:
      - Best case:  1.0 (done, haiku, no retries)
      - Worst case: -1.5 (blocked, opus, 1 retry)
    """
    base = 1.0 if outcome == "done" else -1.0
    retry_penalty = retries * -0.5
    cost_penalty = -COST_WEIGHT[model]
    return base + retry_penalty + cost_penalty
