{
  lib,
  config,
  ...
}: let
  # Stylix Base16 color palette with '#' automatically prepended
  c = config.lib.stylix.colors.withHashtag;
in {
  programs.starship = {
    enable = true;

    enableBashIntegration = true;
    enableFishIntegration = true;
    enableNushellIntegration = true;

    settings = {
      # ── Prompt Layout ───────────────────────────────────────────────────
      format = lib.concatStrings [
        "$os"
        "$directory"
        "$git_branch"
        "$git_status"
        "$nix_shell"
        "$rust"
        "$golang"
        "$nodejs"
        "$bun"
        "$python"
        "$c"
        "$package"
        "$status"
        "$line_break"
        "$character"
      ];

      right_format = "$cmd_duration $time";

      # ── OS Symbol ───────────────────────────────────────────────────────
      os = {
        disabled = false;
        symbols.NixOS = " ";
        style = "bold ${c.base0D}"; # Blue
        format = "[$symbol]($style)";
      };

      # ── Directory Segment (Pill style) ──────────────────────────────────
      directory = {
        style = "bg:${c.base01} fg:${c.base0E} bold"; # Base background + Purple text
        format = " [](${c.base01})[$path]($style)[$read_only]($read_only_style)[](${c.base01}) ";
        truncation_length = 3;
        truncation_symbol = "…/";
        read_only = " 󰌾";
        read_only_style = "bg:${c.base01} fg:${c.base08} bold";
        substitutions = {
          "Documents" = "󰈙 ";
          "Downloads" = " ";
          "Music" = " ";
          "Pictures" = " ";
          "Development" = "󰲋 ";
          "Projects" = "󰲋 ";
          "~" = "󰋜 ";
        };
      };

      # ── Git Branch & Status ─────────────────────────────────────────────
      git_branch = {
        symbol = " ";
        style = "bold ${c.base0C}"; # Cyan
        format = "on [$symbol$branch]($style) ";
      };

      git_status = {
        style = "bold ${c.base08}"; # Red
        format = "([$all_status$ahead_behind]($style) )";
        conflicted = "󰞇 ";
        ahead = "⇡\${count}";
        behind = "⇣\${count}";
        diverged = "⇕⇡\${ahead_count}⇣\${behind_count}";
        untracked = "󰞋 ";
        stashed = "📦 ";
        modified = "📝 ";
        staged = "[+\${count}](bold ${c.base0B}) "; # Green
        renamed = "󰁕 ";
        deleted = "🗑 ";
      };

      # ── Nix Shell Status Badge ──────────────────────────────────────────
      nix_shell = {
        symbol = " ";
        style = "bold ${c.base0D}"; # Blue
        format = "via [](${c.base02})[$symbol$state(\\($name\\))](${c.base0D} bg:${c.base02} bold)[](${c.base02}) ";
        impure_msg = "[impure](bold ${c.base0A} bg:${c.base02})";
        pure_msg = "[pure](bold ${c.base0B} bg:${c.base02})";
        unknown_msg = "";
      };

      # ── Exit Status Module ──────────────────────────────────────────────
      status = {
        disabled = false;
        symbol = "✘ ";
        style = "bold ${c.base08}";
        format = "[$symbol$status]($style) ";
      };

      # ── Language Runtimes ───────────────────────────────────────────────
      rust = {
        symbol = " ";
        style = "bold ${c.base09}"; # Orange
        format = "[$symbol($version)]($style) ";
      };

      nodejs = {
        symbol = "󰎙 ";
        style = "bold ${c.base0B}"; # Green
        format = "[$symbol($version)]($style) ";
      };

      bun = {
        symbol = "🧅 ";
        style = "bold ${c.base0F}"; # Peach / Accent
        format = "[$symbol($version)]($style) ";
      };

      python = {
        symbol = " ";
        style = "bold ${c.base0A}"; # Yellow
        format = "[$symbol$pyenv_prefix($version)(\\($virtualenv\\))]($style) ";
      };

      golang = {
        symbol = " ";
        style = "bold ${c.base0C}"; # Cyan
        format = "[$symbol($version)]($style) ";
      };

      c = {
        symbol = " ";
        style = "bold ${c.base0D}"; # Blue
        format = "[$symbol($version)]($style) ";
      };

      package = {
        symbol = "󰏗 ";
        style = "dimmed ${c.base05}";
        format = "is [$symbol$version]($style) ";
      };

      # ── Right Side: Duration & Time Capsules ────────────────────────────
      cmd_duration = {
        min_time = 2000;
        format = "[](${c.base02})[󰔚 $duration](bg:${c.base02} fg:${c.base0A} bold)[](${c.base02}) ";
      };

      time = {
        disabled = false;
        time_format = "%R";
        format = "[](${c.base02})[󰥔 $time](bg:${c.base02} fg:${c.base05})[](${c.base02})";
      };

      # ── Prompt Character / Cursor ───────────────────────────────────────
      character = {
        success_symbol = "[❯](bold ${c.base0D})";
        error_symbol = "[❯](bold ${c.base08})";
        vimcmd_symbol = "[❮](bold ${c.base0B})";
      };

      # ── Disable Unused Modules ──────────────────────────────────────────
      aws.disabled = true;
      gcloud.disabled = true;
      openstack.disabled = true;
      azure.disabled = true;
    };
  };
}
