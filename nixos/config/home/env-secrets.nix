# nixos/config/home/env-secrets.nix
#
# Single source of truth for "simple" (plain string) secrets. Each entry
# here flows into three places automatically:
#   - sops.secrets.<name>              (sops.nix)
#   - the "secrets-env" sops template  (sops.nix)  -> ~/.config/sops/secrets-env
#   - home.sessionVariables             (variables.nix)
#
# Run `add_env_secret` to append an entry here and encrypt its value in
# secrets.yaml in one step, instead of editing this file by hand.
#
# Fields per entry:
#   name            - sops secret name / primary env var name (required)
#   aliases         - extra env var names that resolve to the same value
#   sessionVariable - set to false to keep it out of the environment entirely:
#                     no Home Manager session variable and no line in the
#                     secrets-env template (so ~/.profile, fish, and
#                     sops-import-environment never export it). The value is
#                     still a sops secret, readable at /run/secrets/<name>.
[
  {
    name = "ANTHROPIC_API_KEY";
    sessionVariable = false; # oauth is used instead
  }
  {
    name = "GOOGLE_AI_API_KEY";
    aliases = ["GEMINI_API_KEY"];
  }
  {name = "OPENROUTER_API_KEY";}
  {name = "SUPABASE_ACCESS_TOKEN";}
  {name = "DEEPSEEK_API_KEY";}
  {name = "OPENCODE_API_KEY";}
  {name = "OPENAI_API_KEY";}
  {
    name = "GITHUB_ACCESS_TOKEN";
    aliases = ["GH_TOKEN"];
  }
  {
    name = "MOONSHOT_API_KEY";
    aliases = ["KIMI_API_KEY"];
  }
  {name = "CONTEXT7_API_KEY";}
  {name = "NPM_PRIVATE_TOKEN";}
  {name = "DEEPINFRA_API_KEY";}
  {name = "GOOGLE_CALENDAR_ICS_URL";}
  {name = "OPENWEATHER_API_KEY";}
]
