# Built-in instance data. This file is deliberately NOT a flake-parts module:
# the leading underscore makes import-tree skip it, and consumers import it by
# relative path instead. Adding a provider here is the whole change (INST-04).
#
# Built-ins carry no envFile and no extraEnv: envFile must stay null so the
# Phase 2 runtime resolution order applies (SHMULCODE_ENV_FILE > XDG/HOME), and
# provider base URLs / model aliases (DeepSeek's deepseek-flash, xAI model ids)
# belong in each user's env file, never in the flake (DIST-01, Core Value).
#
# requiredVars is omitted on purpose: mkLauncher's default already requires
# ANTHROPIC_BASE_URL plus exactly one of ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY,
# which is the shape every supported Anthropic-compatible provider uses.
{
  mimocode = {
    name = "mimocode";
    description = "mimocode — Claude Code via MiMo's Anthropic-compatible endpoint";
  };

  deepcode = {
    name = "deepcode";
    description = "deepcode — Claude Code via DeepSeek's Anthropic-compatible endpoint";
  };

  grokcode = {
    name = "grokcode";
    description = "grokcode — Claude Code via Grok/xAI's Anthropic-compatible endpoint";
  };
}
