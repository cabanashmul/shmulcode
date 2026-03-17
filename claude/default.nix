{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg        = config.programs.claude;
  obsidianCfg = config.programs.claude.mcp.obsidian;

  # Wrapper script that reads the API key at runtime from a sops secret path.
  # Exits immediately if Obsidian is not reachable so claude doesn't hang.
  obsidianMcpWrapper = pkgs.writeShellScript "obsidian-mcp-wrapper" ''
    # Parse host/port from OBSIDIAN_HOST to do a quick reachability check
    HOST="${obsidianCfg.host}"
    # Strip protocol
    HOSTPORT="''${HOST#*://}"
    ADDR="''${HOSTPORT%%/*}"
    IP="''${ADDR%:*}"
    PORT="''${ADDR##*:}"

    if ! ${pkgs.curl}/bin/curl -sk --max-time 2 "$HOST" > /dev/null 2>&1; then
      echo "obsidian-mcp-wrapper: Obsidian not reachable at $HOST, exiting." >&2
      exit 1
    fi

    export OBSIDIAN_API_KEY="$(cat "${obsidianCfg.apiKey}")"
    export OBSIDIAN_HOST="${obsidianCfg.host}"
    exec ${pkgs.nodejs}/bin/npx -y mcp-obsidian "${obsidianCfg.vaultPath}"
  '';

  # Build the mcpServers attrset conditionally
  mcpServers = optionalAttrs obsidianCfg.enable {
    obsidian = {
      command = builtins.toString obsidianMcpWrapper;
      args    = [];
    };
  };

  claudeConfig = {
    inherit mcpServers;
  };

  # ── Auto-discovery ──────────────────────────────────────────────────

  # Discover agent .md files from ./agents/
  agentDir = ./agents;
  discoveredAgents =
    if builtins.pathExists agentDir then
      let entries = builtins.readDir agentDir;
      in filterAttrs (_: v: v == "regular")
         (mapAttrs' (name: type:
           if hasSuffix ".md" name
           then nameValuePair name type
           else nameValuePair name null
         ) entries)
    else {};

  # Discover skill subdirectories from ./skills/
  skillDir = ./skills;
  discoveredSkills =
    if builtins.pathExists skillDir then
      filterAttrs (_: v: v == "directory") (builtins.readDir skillDir)
    else {};

  # Discover command .md files from ./commands/
  commandDir = ./commands;
  discoveredCommands =
    if builtins.pathExists commandDir then
      let entries = builtins.readDir commandDir;
      in filterAttrs (_: v: v == "regular")
         (mapAttrs' (name: type:
           if hasSuffix ".md" name
           then nameValuePair name type
           else nameValuePair name null
         ) entries)
    else {};

  # ── settings.json assembly ──────────────────────────────────────────

  settingsJson = builtins.toJSON (
    { effortLevel = cfg.settings.effortLevel; }
    // optionalAttrs cfg.settings.skipDangerousModePermissionPrompt {
      skipDangerousModePermissionPrompt = true;
    }
    // optionalAttrs (cfg.settings.env != {}) {
      env = cfg.settings.env;
    }
    // cfg.settings.extraSettings
  );

in {
  imports = [
    inputs.shmulistan.homeManagerModules.default
  ];

  # ── Claude Code ──────────────────────────────────────────────────────

  options.programs.claude = {
    enable = mkEnableOption "Claude Code";

    package = mkOption {
      type        = types.package;
      default     = pkgs.claude-code;
      description = "The Claude Code package to install.";
    };

    enableBashIntegration = mkOption {
      type    = types.bool;
      default = true;
    };

    enableZshIntegration = mkOption {
      type    = types.bool;
      default = true;
    };

    # ── Global instructions (CLAUDE.md) ────────────────────────────────

    globalInstructions = mkOption {
      type        = types.lines;
      default     = "";
      description = '' Content for ~/.claude/CLAUDE.md.
        Generated as a symlink via home.file.
      '';
    };

    # ── Settings ───────────────────────────────────────────────────────

    settings = {
      effortLevel = mkOption {
        type    = types.enum [ "low" "medium" "high" ];
        default = "high";
        description = "Claude Code effort level.";
      };

      skipDangerousModePermissionPrompt = mkOption {
        type    = types.bool;
        default = false;
        description = "Whether to skip the dangerous mode permission prompt.";
      };

      env = mkOption {
        type    = types.attrsOf types.str;
        default = {};
        description = "Environment variables to set for Claude Code.";
      };

      extraSettings = mkOption {
        type    = types.attrs;
        default = {};
        description = "Arbitrary extra keys merged into settings.json.";
      };
    };

    # ── Agents ─────────────────────────────────────────────────────────

    agents = {
      enable = mkOption {
        type    = types.bool;
        default = true;
        description = "Whether to deploy discovered agents from ./agents/.";
      };

      extraAgents = mkOption {
        type    = types.attrsOf types.str;
        default = {};
        description = ''
          Additional agents defined inline.
          Keys are filenames (e.g. "my-agent.md"), values are markdown content.
        '';
      };
    };

    # ── Skills ─────────────────────────────────────────────────────────

    skills = {
      enable = mkOption {
        type    = types.bool;
        default = true;
        description = "Whether to deploy discovered skills from ./skills/.";
      };

      extraSkills = mkOption {
        type    = types.attrsOf types.str;
        default = {};
        description = ''
          Additional skills defined inline.
          Keys are skill names (directory names), values are SKILL.md content.
        '';
      };
    };

    # ── Commands ──────────────────────────────────────────────────────

    commands = {
      enable = mkOption {
        type    = types.bool;
        default = true;
        description = "Whether to deploy discovered commands from ./commands/.";
      };

      extraCommands = mkOption {
        type    = types.attrsOf types.str;
        default = {};
        description = ''
          Additional commands defined inline.
          Keys are filenames (e.g. "my-command.md"), values are markdown content.
        '';
      };
    };
  };

  # ── Obsidian MCP ─────────────────────────────────────────────────────

  options.programs.claude.mcp.obsidian = {
    enable = mkEnableOption "Obsidian MCP server for Claude Code memory";

    package = mkOption {
      type        = types.package;
      default     = pkgs.obsidian;
      description = "The Obsidian package to install.";
    };

    apiKey = mkOption {
      type    = types.str;
      default = "";
      description = ''
        Obsidian Local REST API key.
        Either the API key directly, or a path to a file containing it
        (e.g. config.sops.secrets.obsidian_api_key.path).
      '';
    };

    host = mkOption {
      type    = types.str;
      default = "https://127.0.0.1:27124";
      description = "Obsidian Local REST API host.";
    };

    vaultPath = mkOption {
      type    = types.str;
      default = "$HOME/Documents/Obsidian";
      description = "Path to your Obsidian vault.";
    };
  };

  # ── Config ───────────────────────────────────────────────────────────

  config = mkMerge [
    # Claude Code config values
    {
      programs.claude = {
        globalInstructions = ./CLAUDE.md;
        settings = {
          effortLevel = "high";
          skipDangerousModePermissionPrompt = true;
          env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
        };
      };
    }

    # Claude Code core
    (mkIf cfg.enable {
      home.packages = [ cfg.package ];

      # ── claude.json (MCP config) ───────────────────────────────────
      home.activation.claudeJson = mkIf (mcpServers != {}) (lib.hm.dag.entryAfter ["writeBoundary"] ''
        _src=${pkgs.writeText "claude.json" (builtins.toJSON claudeConfig)}
        _dst="$HOME/.claude.json"
        if [ -L "$_dst" ]; then
          $DRY_RUN_CMD rm "$_dst"
        fi
        if ! diff -q "$_src" "$_dst" > /dev/null 2>&1; then
          $DRY_RUN_CMD cp "$_src" "$_dst"
          $DRY_RUN_CMD chmod 644 "$_dst"
        fi
      '');

      # ── settings.json (copy, not symlink) ──────────────────────────
      home.activation.claudeSettings = lib.hm.dag.entryAfter ["writeBoundary"] ''
        _src=${pkgs.writeText "settings.json" settingsJson}
        _dst="$HOME/.claude/settings.json"
        $DRY_RUN_CMD mkdir -p "$HOME/.claude"
        if [ -L "$_dst" ]; then
          $DRY_RUN_CMD rm "$_dst"
        fi
        if ! diff -q "$_src" "$_dst" > /dev/null 2>&1; then
          $DRY_RUN_CMD cp "$_src" "$_dst"
          $DRY_RUN_CMD chmod 644 "$_dst"
        fi
      '';

      # ── CLAUDE.md + Agents + Skills ────────────────────────────────
      home.file = mkMerge [
        # Global instructions
        (mkIf (cfg.globalInstructions != "") {
          ".claude/CLAUDE.md".text = cfg.globalInstructions;
        })
        # Discovered agents from ./agents/
        (mkIf cfg.agents.enable
          (mapAttrs' (name: _:
            nameValuePair ".claude/agents/${name}" {
              source = ./agents/${name};
            }
          ) discoveredAgents))

        # Inline extra agents
        (mapAttrs' (name: content:
          nameValuePair ".claude/agents/${name}" {
            text = content;
          }
        ) cfg.agents.extraAgents)

        # Discovered skills from ./skills/
        (mkIf cfg.skills.enable
          (mapAttrs' (name: _:
            nameValuePair ".claude/skills/${name}/SKILL.md" {
              source = ./skills/${name}/SKILL.md;
            }
          ) discoveredSkills))

        # Inline extra skills
        (mapAttrs' (name: content:
          nameValuePair ".claude/skills/${name}/SKILL.md" {
            text = content;
          }
        ) cfg.skills.extraSkills)

        # Discovered commands from ./commands/
        (mkIf cfg.commands.enable
          (mapAttrs' (name: _:
            nameValuePair ".claude/commands/${name}" {
              source = ./commands/${name};
            }
          ) discoveredCommands))

        # Inline extra commands
        (mapAttrs' (name: content:
          nameValuePair ".claude/commands/${name}" {
            text = content;
          }
        ) cfg.commands.extraCommands)
      ];

      # ── Shell completions ──────────────────────────────────────────
      programs.bash.initExtra = mkIf cfg.enableBashIntegration ''
        if command -v claude &>/dev/null; then
          _claude_comp=$(mktemp)
          if timeout 5 claude completion bash > "$_claude_comp" 2>/dev/null; then
            source "$_claude_comp"
          fi
          rm -f "$_claude_comp"
          unset _claude_comp
        fi
      '';

      programs.zsh.initContent = mkIf cfg.enableZshIntegration ''
        if (( $+commands[claude] )); then
          _claude_comp=$(mktemp)
          if timeout 5 claude completion zsh > "$_claude_comp" 2>/dev/null; then
            source "$_claude_comp"
          fi
          rm -f "$_claude_comp"
          unset _claude_comp
        fi
      '';
    })

    # Obsidian MCP
    (mkIf obsidianCfg.enable {
      home.packages = [ obsidianCfg.package ];
      assertions = [
        {
          assertion = obsidianCfg.apiKey != "";
          message   = "programs.claude.mcp.obsidian.apiKey must be set when obsidian MCP is enabled.";
        }
      ];
    })

    # Shmulistan vault
    (mkIf cfg.enable {
      programs.shmulistan.enable = true;
    })
  ];
}
