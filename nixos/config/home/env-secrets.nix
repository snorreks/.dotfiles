# nixos/config/home/env-secrets.nix
#
# Simple SOPS credentials. sops.nix generates a names-only manifest from this
# list. Interactive fish exports all ready session credentials for CLI tools;
# secret-env also supports explicit credentials and scoped child processes.
# aliases add environment variable names for the same value.
# sessionVariable = false keeps a key out of automatic loading (Anthropic OAuth).
# Run add_env_secret to register and encrypt a new credential.
[
  {
    name = "ANTHROPIC_API_KEY";
    sessionVariable = false; # oauth is used instead
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
  {name = "GEMINI_API_KEY";}
]
