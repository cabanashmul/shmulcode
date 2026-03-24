# shmulcode

A Nix-managed Claude Code configuration framework. Declaratively manage agents, skills, commands, settings, and a Q-learning model router — all deployed via a home-manager module. Everything is auto-discovered from the repository directory structure and symlinked to `~/.claude/` on `home-manager switch`.

## Overview

shmulcode provides a declarative, reproducible system for configuring Claude Code with:

- **22 agents** organized by role (planner, advisors, specialists, QA, post-agents)
- **5 reusable skills** for common tasks (Nix, Git, Kubernetes, debugging, skill creation)
- **Command definitions** for custom shortcuts
- **Q-learning model router** that learns optimal model assignments via reinforcement learning
- **Obsidian vault integration** for persistent knowledge management
- **Home-manager module** that auto-discovers and deploys everything

## Repository Structure

```
shmulcode/
├── README.md                      # This file
├── CLAUDE.md                      # Project instructions (system context for agents)
├── flake.nix                      # Minimal Nix entry point (uses flake-parts)
├── agents/                        # 22 agent definitions (.md files with YAML frontmatter)
├── skills/                        # 5 skill definitions (subdirectories with SKILL.md)
├── commands/                      # Command definitions (.md files)
├── qrouter/                       # Q-learning model router (Python package)
├── modules/
│   └── home-manager.nix           # Home-manager module (auto-discovery + symlink)
└── .claude/                       # Local Claude Code settings
```

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/shmul95/shmulcode ~/Repositories/shmulcode
```

### 2. Add to Home Manager configuration

Edit your `flake.nix` or Home Manager configuration:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    shmulcode = {
      url = "file:///home/youruser/Repositories/shmulcode";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, home-manager, shmulcode }:
    {
      homeConfigurations.youruser = home-manager.lib.homeManagerConfiguration {
        # ... other config ...
        modules = [
          "${shmulcode}/modules/home-manager.nix"
          {
            programs.claude = {
              enable = true;
              agents.enable = true;
              skills.enable = true;
              commands.enable = true;
              vault.enable = true;
              qrouter.enable = true;
              qrouter.repoPath = "${shmulcode}";
            };
          }
        ];
      };
    };
}
```

### 3. Deploy

```bash
home-manager switch
```

This will:
- Symlink all agents, skills, and commands to `~/.claude/`
- Generate `~/.claude/settings.json` with qrouter hooks (if enabled)
- Generate `~/.claude.json` for MCP server configuration
- Install shell completions (bash/zsh)
- Clone the shmulistan vault (if enabled)

## Architecture

### Execution Protocol

The system follows a structured workflow for delegating work:

```
1. manager (planner)
   ├── Researches codebase and vault
   └── Returns structured execution plan

2. advisors (parallel)
   ├── security-advisor: auth, PII, secrets
   ├── architecture-advisor: design, services
   ├── performance-advisor: hot paths, latency
   ├── cost-advisor: infrastructure costs
   └── dependency-advisor: new libraries
   └── Return constraints (not code)

3. specialists (parallel with dependencies)
   ├── app-specialist: CLI tools, games, desktop apps
   ├── backend-specialist: APIs, server logic
   ├── frontend-specialist: React, TypeScript, UI
   ├── db-specialist: schemas, migrations, queries
   ├── iac-specialist: Nix, Helm, Terraform
   ├── devops-specialist: CI/CD, deployment
   ├── finance-specialist: billing, payments
   ├── network-specialist: ingress, DNS, TLS
   ├── data-specialist: ETL, analytics
   └── qa-specialist: test strategy, coverage
   └── Implement code, return results

4. auditor
   └── Verifies implementation against constraints

5. Post-agents (sequential chain)
   ├── tester: runs tests, returns PASS/FAIL
   ├── committer: creates atomic git commit
   ├── documenter: updates READMEs, API docs
   └── learner: writes vault notes
```

Each agent has a specific role, model assignment, and set of tools. Agents are invoked via the `Agent()` tool in Claude Code conversations.

### Agent Roster

#### Planner
| Agent | Model | Purpose |
|-------|-------|---------|
| manager | opus | Researches codebase, searches vault, returns structured plan |

#### Advisors (no tools, context embedded in prompt)
| Agent | Model | Purpose |
|-------|-------|---------|
| security-advisor | opus | Auth, PII, external I/O, secrets, RBAC |
| architecture-advisor | opus | New services, cross-cutting changes, schema design |
| performance-advisor | sonnet | Hot paths, DB queries, API latency |
| cost-advisor | haiku | IaC changes, scaling config, new infra resources |
| dependency-advisor | haiku | New libraries, services, external dependencies |

#### Specialists (write code, return output contracts)
| Agent | Model | Purpose |
|-------|-------|---------|
| app-specialist | sonnet | Games, desktop apps, CLI tools, scripts |
| backend-specialist | sonnet | APIs, server logic, auth, business rules |
| frontend-specialist | sonnet | React, TypeScript, HTML, CSS, client-side |
| db-specialist | sonnet | Schema, migrations, queries, data modelling |
| iac-specialist | sonnet | Nix flakes, Helm, Terraform, env config |
| devops-specialist | sonnet | CI/CD pipelines, deployment automation, monitoring |
| finance-specialist | sonnet | Billing, payments, invoicing, pricing |
| network-specialist | sonnet | Ingress, DNS, TLS, service mesh, load balancing |
| data-specialist | sonnet | ETL, pipelines, analytics schema, reporting |

#### QA
| Agent | Model | Purpose |
|-------|-------|---------|
| qa-specialist | sonnet | Test strategy, coverage standards, pass conditions |

#### Auditor
| Agent | Model | Purpose |
|-------|-------|---------|
| auditor | sonnet | Verifies specialist output against advisor constraints |

#### Post-agents
| Agent | Model | Purpose |
|-------|-------|---------|
| tester | sonnet | Pre-checks, tests, code review → PASS/FAIL verdict |
| committer | haiku | Atomic git commit (only agent that commits) |
| documenter | haiku | READMEs, API docs, changelogs |
| learner | sonnet | Zettelkasten notes, vault pruning |

#### Standalone
| Agent | Model | Purpose |
|-------|-------|---------|
| teacher | opus | Rustlings-style programming tutor (invoked with `claude --agent teacher`) |

## Components

### Agents

Agents are defined in `agents/` as `.md` files with YAML frontmatter:

```yaml
---
name: my-agent
description: Agent description
model: opus | sonnet | haiku
tools: Read, Glob, Grep, ...
skills:
  - skill-name
---

Agent prompt and instructions...
```

All agents are auto-discovered and symlinked to `~/.claude/agents/`. Add a new agent by creating a new `.md` file in `agents/`.

### Skills

Skills are reusable knowledge modules. Each skill lives in `skills/<name>/SKILL.md` and can be referenced by agents.

Available skills:

| Skill | Description |
|-------|-------------|
| nix-flake-parts | Nix flake architecture using dendritic pattern, flake-parts, and import-tree |
| git-worktrees | Isolated parallel development using git worktrees |
| k8s-nix-deployment | Kubernetes + Nix container images |
| skill-creator | Guide for creating new skills |
| systematic-debugging | Root-cause-first debugging methodology |

Add a new skill by creating `skills/<name>/SKILL.md`.

### Commands

Commands are custom shortcuts. Define them in `commands/` as `.md` files. They are symlinked to `~/.claude/commands/`.

### Q-learning Model Router (qrouter)

The qrouter learns optimal model assignments via reinforcement learning. It tracks Q-values for each (agent, model) pair and uses epsilon-greedy exploration to balance exploitation and exploration.

**Enable in Home Manager:**

```nix
programs.claude.qrouter = {
  enable = true;
  repoPath = "/path/to/shmulcode";  # absolute path to repo root
};
```

**Key features:**

- **PreToolUse hook**: Recommends a model based on Q-table values
- **PostToolUse hook**: Records outcomes and updates Q-values
- **CLI commands**: suggest, record, status, history, apply, export, reset
- **Reward function**: Incentivizes cheap models that succeed
- **Experience replay**: Mini-batch training on recorded experiences

See [qrouter/README.md](qrouter/README.md) for complete documentation.

### Vault Integration

The system integrates with the shmulistan Obsidian vault at `~/shmulistan` for persistent knowledge management:

- **Learner agent** writes Zettelkasten notes after implementation
- **Manager agent** searches the vault for prior knowledge and context
- **Auto-clone**: Vault is cloned on first `home-manager switch` if `vault.enable = true`

**Enable in Home Manager:**

```nix
programs.claude.vault = {
  enable = true;
  path = "${config.home.homeDirectory}/shmulistan";
  repoUrl = "https://github.com/shmul95/shmulistan.git";
};
```

## Configuration

The home-manager module provides fine-grained configuration:

### Core Settings

```nix
programs.claude = {
  enable = true;                          # Enable Claude Code
  package = pkgs.claude-code;             # Claude Code package

  # Global instructions
  globalInstructions = builtins.readFile ../CLAUDE.md;

  # Settings for ~/.claude/settings.json
  settings = {
    effortLevel = "high";                 # low | medium | high
    skipDangerousModePermissionPrompt = true;
    env = {
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
    };
    extraSettings = {};                   # Arbitrary extra keys
  };

  # Shell integrations
  enableBashIntegration = true;
  enableZshIntegration = true;
};
```

### Agents, Skills, Commands

```nix
programs.claude = {
  agents = {
    enable = true;                        # Auto-discover from agents/
    extraAgents = {
      "my-agent.md" = "...";              # Define inline
    };
  };

  skills = {
    enable = true;                        # Auto-discover from skills/
    extraSkills = {
      "my-skill" = "...";                 # Define inline
    };
  };

  commands = {
    enable = true;                        # Auto-discover from commands/
    extraCommands = {
      "my-command.md" = "...";            # Define inline
    };
  };
};
```

### MCP Servers

Configure Model Context Protocol servers:

```nix
programs.claude.mcp.servers = {
  my-server = {
    command = "python3";
    args = [ "-m" "my_server" ];
    env = { MY_VAR = "value"; };
  };
};
```

### Q-learning Router

```nix
programs.claude.qrouter = {
  enable = true;
  repoPath = "/path/to/shmulcode";       # Absolute path to repo root
};
```

### Vault

```nix
programs.claude.vault = {
  enable = true;
  path = "${config.home.homeDirectory}/shmulistan";
  repoUrl = "https://github.com/shmul95/shmulistan.git";
};
```

## File Organization

### Agent Frontmatter

```yaml
---
name: string                    # Agent name (used by Claude Code)
description: string             # One-line description
model: opus|sonnet|haiku        # Model assignment (can be updated by qrouter)
tools: Tool1, Tool2, ...        # Tools available to agent
skills:                         # Optional list of skills to reference
  - skill-name
---
```

### Skill Structure

```
skills/my-skill/
├── SKILL.md                     # Content (referenced by agents)
└── README.md                    # Optional documentation
```

### Home-Manager Output

After `home-manager switch`:

```
~/.claude/
├── CLAUDE.md                    # Global instructions
├── settings.json                # Claude Code settings (auto-generated)
├── agents/
│   ├── manager.md
│   ├── tester.md
│   └── ...
├── skills/
│   ├── nix-flake-parts/
│   │   └── SKILL.md
│   └── ...
└── commands/
    ├── my-command.md
    └── ...

~/.claude.json                   # MCP configuration (if mcp.servers configured)
~/.qrouter_data/                 # Q-table, history, config (if qrouter enabled)
~/shmulistan/                    # Vault clone (if vault enabled)
```

## Development

### Adding a New Agent

1. Create `agents/my-agent.md`:

```yaml
---
name: my-agent
description: Agent description
model: sonnet
tools: Read, Glob, Grep
skills: []
---

Agent prompt and instructions...
```

2. Run `home-manager switch` to deploy

3. Invoke with `claude --agent my-agent`

### Adding a New Skill

1. Create `skills/my-skill/SKILL.md`:

```yaml
---
name: my-skill
description: Skill description
---

Skill content and guidance...
```

2. Run `home-manager switch` to deploy

3. Reference in agent frontmatter: `skills: [my-skill]`

### Testing Configuration Locally

```bash
cd shmulcode
nix develop                      # Enter dev shell
python3 -m qrouter status        # Test qrouter (if enabled)
```

## Usage

### Direct Agent Invocation

```bash
claude --agent manager --conversation "Describe the task"
```

### Teacher Agent

The teacher agent provides rustlings-style progressive exercises:

```bash
claude --agent teacher --conversation "Teach me Rust basics"
```

Features:
- Progressive exercises with heavy comments
- Test-driven verification
- 3-tier hint system
- Quizzes between sections
- Capstone projects
- Session persistence

### Q-learning Router CLI

```bash
# Suggest best model for an agent
python3 -m qrouter suggest --agent manager

# Record an outcome
python3 -m qrouter record --agent manager --model opus --outcome done --retries 0

# View Q-table status
python3 -m qrouter status

# View training history
python3 -m qrouter history --last 50

# Apply best models to agent .md files
python3 -m qrouter apply --agents-dir ./agents

# Export snapshot
python3 -m qrouter export --output snapshot.json

# Reset Q-table
python3 -m qrouter reset
```

See [qrouter/README.md](qrouter/README.md) for complete CLI documentation.

## Dependencies

### Nix

- `nixpkgs`: NixOS package repository
- `flake-parts`: Modular flake architecture
- `import-tree`: Dendritic pattern for flake modules

### Runtime

- `python3.8+`: For qrouter hooks and CLI
- `git`: For vault integration
- `obsidian`: For vault editing (optional)

## Files of Note

- **CLAUDE.md**: Project-wide instructions and execution protocol
- **flake.nix**: Minimal Nix entry point (uses flake-parts)
- **modules/home-manager.nix**: Home-manager module with auto-discovery logic
- **qrouter/config.py**: Q-learning hyperparameters
- **agents/manager.md**: Planner agent definition
- **skills/**: Reusable skill modules

## See Also

- [CLAUDE.md](CLAUDE.md): Full execution protocol and agent definitions
- [qrouter/README.md](qrouter/README.md): Q-learning model router documentation
- [flake.nix](flake.nix): Nix flake structure
- [modules/home-manager.nix](modules/home-manager.nix): Home-manager module implementation

## License

This project is maintained as a personal Nix configuration. Feel free to fork and adapt.
