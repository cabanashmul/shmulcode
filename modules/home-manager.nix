{ inputs, ... }: {
  flake.homeManagerModules.default = { config, lib, pkgs, ... }:

    with lib;

    let
      cfg = config.programs.claude;

      # ── Auto-discovery ──────────────────────────────────────────────────

      # Discover agent .md files from ../agents/
      agentDir = ../agents;
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

      # Discover skill subdirectories from ../skills/
      skillDir = ../skills;
      discoveredSkills =
        if builtins.pathExists skillDir then
          filterAttrs (_: v: v == "directory") (builtins.readDir skillDir)
        else {};

      # Discover command .md files from ../commands/
      commandDir = ../commands;
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

      stripMdSuffix = name:
        if hasSuffix ".md" name
        then removeSuffix ".md" name
        else name;

      discoveredAgentNames = map stripMdSuffix (attrNames discoveredAgents);
      discoveredSkillNames = attrNames discoveredSkills;
      discoveredCommandNames = map stripMdSuffix (attrNames discoveredCommands);

      validateEnabledKeys = category: validNames: enabledMap:
        let
          invalid = filter (name: !(elem name validNames)) (attrNames enabledMap);
          validList = concatStringsSep ", " validNames;
          invalidList = concatStringsSep ", " invalid;
        in
          if invalid == [] then
            true
          else
            throw "programs.claude.${category}.enabled contains unknown ${category}: ${invalidList}. Valid names: ${validList}";

      _validateAgentKeys =
        validateEnabledKeys "agents" discoveredAgentNames cfg.agents.enabled;
      _validateSkillKeys =
        validateEnabledKeys "skills" discoveredSkillNames cfg.skills.enabled;
      _validateCommandKeys =
        validateEnabledKeys "commands" discoveredCommandNames cfg.commands.enabled;

      agentEnabled = name: (cfg.agents.enabled.${name} or true);
      skillEnabled = name: (cfg.skills.enabled.${name} or true);
      commandEnabled = name: (cfg.commands.enabled.${name} or true);

      # ── settings.json assembly ──────────────────────────────────────────

      qrouterHooks = optionalAttrs cfg.qrouter.enable {
        hooks = {
          PreToolUse = [{
            matcher = "Agent";
            hooks = [{
              type    = "command";
              command = "PYTHONPATH=${cfg.qrouter.repoPath} python3 -m qrouter.hooks.pre_tool_use";
              timeout = 5000;
            }];
          }];
          PostToolUse = [{
            matcher = "Agent";
            hooks = [{
              type    = "command";
              command = "PYTHONPATH=${cfg.qrouter.repoPath} python3 -m qrouter.hooks.post_tool_use";
              timeout = 10000;
            }];
          }];
        };
      };

      settingsJson = builtins.toJSON (
        recursiveUpdate
          ({ effortLevel = cfg.settings.effortLevel; }
           // optionalAttrs cfg.settings.skipDangerousModePermissionPrompt {
             skipDangerousModePermissionPrompt = true;
           }
           // optionalAttrs (cfg.settings.env != {}) {
             env = cfg.settings.env;
           }
           // cfg.settings.extraSettings)
          qrouterHooks
      );

      # ── MCP config assembly ────────────────────────────────────────────

      mcpConfig = {
        mcpServers = mapAttrs (_: srv: {
          inherit (srv) command args;
        } // optionalAttrs (srv.env != {}) {
          inherit (srv) env;
        }) cfg.mcp.servers;
      };

    in {
      # ── Imported sibling modules ────────────────────────────────────────
      # claude-routine adds programs.claude.routines.* options (e.g.
      # d4aJiraTicket morning routine). Sandboxed systemd-user units only
      # materialise when the routine is enabled.
      imports = [ inputs.claude-routine.homeManagerModules.default ];

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
            default = true;
            description = "Whether to skip the dangerous mode permission prompt.";
          };

          env = mkOption {
            type    = types.attrsOf types.str;
            default = {
              CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
            };
            description = "Environment variables to set for Claude Code.";
          };

          extraSettings = mkOption {
            type    = types.attrs;
            default = {};
            description = "Arbitrary extra keys merged into settings.json.";
          };
        };

        # ── MCP Servers ──────────────────────────────────────────────────

        mcp.servers = mkOption {
          type = types.attrsOf (types.submodule {
            options = {
              command = mkOption {
                type = types.str;
                description = "Command to run the MCP server.";
              };
              args = mkOption {
                type    = types.listOf types.str;
                default = [];
                description = "Arguments to pass to the MCP server command.";
              };
              env = mkOption {
                type    = types.attrsOf types.str;
                default = {};
                description = "Environment variables for the MCP server.";
              };
            };
          });
          default = {};
          description = "MCP servers to configure in ~/.claude.json";
        };

        # ── Jira MCP integration ─────────────────────────────────────────────
        mcp.jira = {
          enable = mkEnableOption "Jira MCP server (ListMyIssues, GetIssue tools)";
          envFile = mkOption {
            type = types.str;
            default = "${config.home.homeDirectory}/.config/jira-mcp/.env";
            description = "Path to dotenv file containing JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN.";
          };
        };

        # ── Vault ────────────────────────────────────────────────────────

        vault = {
          enable = mkOption {
            type    = types.bool;
            default = true;
            description = "Whether to enable the shmulistan knowledge vault.";
          };

          path = mkOption {
            type        = types.str;
            default     = "${config.home.homeDirectory}/shmulistan";
            description = "Path to the shmulistan vault.";
          };

          repoUrl = mkOption {
            type        = types.str;
            default     = "https://github.com/shmul95/shmulistan.git";
            description = "Git URL to clone the vault from if not present.";
          };
        };

        # ── Agents ─────────────────────────────────────────────────────────

        agents = {
          enable = mkOption {
            type    = types.bool;
            default = true;
            description = "Whether to deploy discovered agents from agents/.";
          };

          enabled = mkOption {
            type    = types.attrsOf types.bool;
            default = {};
            example = { "finance-specialist" = false; };
            description = ''
              Per-agent enable overrides for discovered agents.
              Discovered agents are enabled by default unless explicitly set to false.
            '';
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
            description = "Whether to deploy discovered skills from skills/.";
          };

          enabled = mkOption {
            type    = types.attrsOf types.bool;
            default = {};
            example = { "git-worktrees" = false; };
            description = ''
              Per-skill enable overrides for discovered skills.
              Discovered skills are enabled by default unless explicitly set to false.
            '';
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
            description = "Whether to deploy discovered commands from commands/.";
          };

          enabled = mkOption {
            type    = types.attrsOf types.bool;
            default = {};
            example = { "commit" = false; };
            description = ''
              Per-command enable overrides for discovered commands.
              Discovered commands are enabled by default unless explicitly set to false.
            '';
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

        # ── Q-learning model router ────────────────────────────────────────

        qrouter = {
          enable = mkOption {
            type    = types.bool;
            default = false;
            description = ''
              Whether to register qrouter PreToolUse/PostToolUse hooks in settings.json.
              Requires the qrouter/ Python package to be present at repoPath.
            '';
          };

          repoPath = mkOption {
            type        = types.str;
            default     = "${config.home.homeDirectory}/Repositories/shmulcode";
            description = ''
              Absolute path to the shmulcode repository root where qrouter/ lives.
              Used as PYTHONPATH when invoking the hook modules.
            '';
          };
        };
      };

      # ── Config ───────────────────────────────────────────────────────────

      config = mkMerge [
        {
          assertions = [
            {
              assertion = _validateAgentKeys;
              message = "programs.claude.agents.enabled contains unknown agent names.";
            }
            {
              assertion = _validateSkillKeys;
              message = "programs.claude.skills.enabled contains unknown skill names.";
            }
            {
              assertion = _validateCommandKeys;
              message = "programs.claude.commands.enabled contains unknown command names.";
            }
          ];
        }

        # Default global instructions
        {
          programs.claude.globalInstructions = builtins.readFile ../CLAUDE.md;
        }

        # Jira MCP server injection (lazy — only built when enabled)
        (mkIf cfg.mcp.jira.enable {
          programs.claude.mcp.servers.jira = {
            command = "${inputs.jira-mcp.packages.${pkgs.system}.default}/bin/jira-mcp";
            args = [];
            env = { JIRA_MCP_ENV_FILE = cfg.mcp.jira.envFile; };
          };
        })

        # Claude Code core
        (mkIf cfg.enable {
          home.packages = [ cfg.package ];

          # ── claude.json (MCP config) ───────────────────────────────────
          home.activation.claudeJson = mkIf (cfg.mcp.servers != {}) (lib.hm.dag.entryAfter ["writeBoundary"] ''
            _src=${pkgs.writeText "claude.json" (builtins.toJSON mcpConfig)}
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
            # Discovered agents from ../agents/
            (mkIf cfg.agents.enable
              (mapAttrs' (name: _:
                let canonicalName = stripMdSuffix name;
                in nameValuePair ".claude/agents/${name}" {
                  source = ../agents/${name};
                }
              ) (filterAttrs (name: _: agentEnabled (stripMdSuffix name)) discoveredAgents)))

            # Inline extra agents
            (mapAttrs' (name: content:
              nameValuePair ".claude/agents/${name}" {
                text = content;
              }
            ) cfg.agents.extraAgents)

            # Discovered skills from ../skills/
            (mkIf cfg.skills.enable
              (mapAttrs' (name: _:
                nameValuePair ".claude/skills/${name}/SKILL.md" {
                  source = ../skills/${name}/SKILL.md;
                }
              ) (filterAttrs (name: _: skillEnabled name) discoveredSkills)))

            # Inline extra skills
            (mapAttrs' (name: content:
              nameValuePair ".claude/skills/${name}/SKILL.md" {
                text = content;
              }
            ) cfg.skills.extraSkills)

            # Discovered commands from ../commands/
            (mkIf cfg.commands.enable
              (mapAttrs' (name: _:
                nameValuePair ".claude/commands/${name}" {
                  source = ../commands/${name};
                }
              ) (filterAttrs (name: _: commandEnabled (stripMdSuffix name)) discoveredCommands)))

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

        # qrouter hooks: python3 runtime
        (mkIf cfg.qrouter.enable {
          home.packages = [ pkgs.python3 ];
        })

        # Shmulistan vault clone activation
        (mkIf cfg.vault.enable {
          home.packages = [ pkgs.obsidian ];

          home.activation.shmulistan-clone = lib.hm.dag.entryAfter ["writeBoundary"] ''
            if [ ! -d "${cfg.vault.path}" ]; then
              $DRY_RUN_CMD ${pkgs.git}/bin/git clone "${cfg.vault.repoUrl}" "${cfg.vault.path}"
            fi
          '';
        })
      ];
    };
}
