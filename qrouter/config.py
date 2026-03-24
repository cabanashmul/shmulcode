from pathlib import Path

MODELS = ["haiku", "sonnet", "opus"]
ALPHA = 0.1          # Learning rate
GAMMA = 0.0          # Independent episodes (contextual bandit)
EPSILON_INIT = 0.5
EPSILON_DECAY = 0.995
EPSILON_MIN = 0.01
REPLAY_BUFFER_SIZE = 1000
REPLAY_BATCH_SIZE = 16
DATA_DIR = Path.home() / ".claude" / "qrouter"

PINNED_AGENTS = {
    "manager": "opus",
    "security-advisor": "opus",
    "architecture-advisor": "opus",
}

COST_WEIGHT = {
    "haiku": 0.00,
    "sonnet": 0.15,
    "opus": 0.50,
}

CURRENT_ASSIGNMENTS = {
    "backend-specialist": "sonnet",
    "frontend-specialist": "sonnet",
    "db-specialist": "sonnet",
    "iac-specialist": "sonnet",
    "devops-specialist": "sonnet",
    "app-specialist": "sonnet",
    "finance-specialist": "sonnet",
    "network-specialist": "sonnet",
    "data-specialist": "sonnet",
    "performance-advisor": "sonnet",
    "qa-specialist": "sonnet",
    "tester": "sonnet",
    "learner": "sonnet",
    "committer": "haiku",
    "documenter": "haiku",
    "cost-advisor": "haiku",
    "dependency-advisor": "haiku",
}
