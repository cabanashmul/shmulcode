# qrouter

A Q-learning model router for Claude Code agent types. Uses reinforcement learning to intelligently select the best model (opus, sonnet, or haiku) for each agent based on historical performance outcomes.

## Overview

qrouter learns which models work best for which agent types by:

1. **Pre-tool-use hook**: Reads the Agent invocation and recommends a model based on Q-table values
2. **Post-tool-use hook**: Records the outcome (PASS/FAIL, done/blocked) and updates Q-values via replay buffer training
3. **Q-table learning**: Tracks Q-values for each (agent, model) pair using epsilon-greedy exploration

The system balances exploration (trying other models) and exploitation (using the best known model) through epsilon decay.

## Installation & Setup

### Prerequisites
- Python 3.8+
- The shmulcode repo cloned locally

### Enable qrouter in Claude Code

Edit your Home Manager configuration (or nix flake):

```nix
programs.claude.qrouter = {
  enable = true;
  repoPath = "/home/youruser/Repositories/shmulcode";  # path to qrouter/
};
```

Then run `home-manager switch` to install hooks into `~/.claude/settings.json`.

The hooks will:
- Intercept `Agent()` tool calls (PreToolUse)
- Parse agent outcomes and record experiences (PostToolUse)
- Update the Q-table automatically

## CLI Usage

### Suggest a model for an agent

```bash
python3 -m qrouter suggest --agent manager
```

Output:
```json
{
  "model": "opus",
  "exploration": false,
  "q_values": {"opus": 0.85, "sonnet": 0.72, "haiku": 0.50},
  "epsilon": 0.123456,
  "pinned": false
}
```

- `model`: recommended model
- `exploration`: true if this is an exploratory choice (not the current best)
- `q_values`: all Q-values for this agent
- `epsilon`: current exploration rate
- `pinned`: whether agent has a fixed model assignment

### Record an outcome

```bash
python3 -m qrouter record \
  --agent manager \
  --model opus \
  --outcome done \
  --retries 0
```

Updates the Q-table using the reward function and mini-batch replay. Outputs:

```json
{
  "agent": "manager",
  "model": "opus",
  "outcome": "done",
  "retries": 0,
  "reward": 0.9500,
  "episode": 42
}
```

### View Q-table status

```bash
python3 -m qrouter status
```

Or for a specific agent:

```bash
python3 -m qrouter status --agent manager
```

Output:
```
Epsilon: 0.123456  Episode: 42

Agent          opus    sonnet     haiku  Best
─────────────────────────────────────────────
manager       0.8500   0.7200   0.5000  opus
tester        0.9100   0.8500   0.6200  opus
committer     0.7500   0.7000   0.8900  haiku

Pinned agents (not in Q-table):
  security-advisor: opus
  architecture-advisor: opus
```

### View training history

```bash
python3 -m qrouter history --last 50
```

Shows recent recorded experiences with timestamps, rewards, and episodes.

### Apply best models to agent .md files

```bash
python3 -m qrouter apply --agents-dir /path/to/agents
```

Updates each agent's YAML frontmatter with the best model from Q-table:

```yaml
---
name: manager
model: opus  # <- updated to best model
---
```

Pinned agents are never modified.

### Export Q-table snapshot

```bash
python3 -m qrouter export --output snapshot.json
```

Saves a complete snapshot including Q-table state, epsilon, episode count, and configuration.

### Reset Q-table

```bash
python3 -m qrouter reset
```

Resets all Q-values to priors, epsilon to initial value, and episode to 0.

## Configuration

Edit `/qrouter/config.py` to customize:

```python
# Learning hyperparameters
ALPHA = 0.1                    # learning rate
EPSILON_INIT = 0.3            # initial exploration rate
EPSILON_DECAY = 0.995         # decay per episode
EPSILON_MIN = 0.01            # minimum exploration rate
REPLAY_BATCH_SIZE = 8         # mini-batch size for experience replay

# Available models
MODELS = ["opus", "sonnet", "haiku"]

# Pinned agents (fixed model, not learned)
PINNED_AGENTS = {
    "security-advisor": "opus",
    "architecture-advisor": "opus",
    "qa-specialist": "sonnet",
}

# Data directory (stores Q-table, history, config)
DATA_DIR = Path.home() / ".qrouter_data"
```

## Reward Function

The reward function in `reward.py` computes:

```
reward = outcome_bonus - model_cost - retry_penalty
```

Where:
- `outcome_bonus`: +1.0 for "done", +0.0 for "blocked"
- `model_cost`: higher cost for expensive models (opus > sonnet > haiku)
- `retry_penalty`: penalty increases with number of retries

This incentivizes finding the cheapest model that still succeeds.

## Data Files

qrouter stores state in `~/.qrouter_data/`:

- `qtable.json`: Q-values, epsilon, episode count (locked during updates)
- `replay.json`: experience buffer for mini-batch training
- `config.json`: training state (epsilon, episode)
- `history.csv`: timestamped log of all recorded experiences

All file writes are atomic (via flock + temp file + rename).

## Hooks Integration

### PreToolUse Hook

- Reads Agent invocations
- Looks up best (or exploratory) model for agent
- Inserts system message recommending the model
- Automatically approved

Example system message:
```
Q-ROUTER: recommend model="opus" for agent="manager" (exploitation, Q=0.85, ε=0.10)
```

### PostToolUse Hook

- Parses agent output for STATUS or VERDICT keywords
- Maps to outcome: "done" (PASS), "blocked" (FAIL)
- Records (agent, model, outcome) in replay buffer
- Updates Q-table via locked operation
- Appends to history.csv

On any error, silently approves without recording.

## Development

Run CLI from the repo:

```bash
PYTHONPATH=/path/to/shmulcode python3 -m qrouter <command> [args]
```

Or install in development mode:

```bash
cd /path/to/shmulcode
pip install -e .
qrouter <command> [args]
```

## Files

- `__init__.py`: Package version
- `__main__.py`: Entry point (redirects to cli.main())
- `cli.py`: Command implementations
- `config.py`: Hyperparameters and constants
- `qtable.py`: Q-table state, epsilon decay, model suggestion
- `replay.py`: Experience replay buffer
- `reward.py`: Reward computation
- `hooks/pre_tool_use.py`: PreToolUse hook module
- `hooks/post_tool_use.py`: PostToolUse hook module

## See Also

- [../CLAUDE.md](../CLAUDE.md): Overall system architecture and execution protocol
- [../agents/](../agents/): Agent definitions and model assignments
- [../README.md](../README.md): Main repository documentation
