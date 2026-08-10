# nixos/config/home/theme/apps/starship.nix
#
# ── Why this replaces the right_format + fish_prompt splice ────────────────
#
# The old design put $cmd_duration/$time in starship's `right_format`, then
# overrode `fish_prompt` to render the prompt twice and splice the right block
# onto the first line. That works, but it costs:
#
#   • two `starship prompt` execs per keystroke-to-prompt (roughly doubles
#     prompt latency; most visible in a large git repo)
#   • a hand-maintained copy of starship's fish init internals
#     (__starship_set_job_count, STARSHIP_KEYMAP, --pipestatus wiring) that
#     silently drifts on every starship upgrade
#   • no transient prompt (--final-rendering branch dropped)
#   • fish only — bash/nushell still get the block in the wrong place
#
# None of it is necessary: starship ships a `fill` module that pads to the
# terminal width mid-`format`. Putting `$fill$cmd_duration$time` BEFORE
# `$line_break` puts the block flush-right on the *directory* line, natively,
# in one render, in every shell — and leaves the `❯` line completely empty to
# the right, which was the actual requirement.
#
#   󰋜 ~/dev/nordclaw  main !2                    󰔚 3s  14:38
#   ❯ ▏                             ← nothing to the right, ever
#
# ── Why the powerline pills are gone ──────────────────────────────────────
#
# base16's contract is that base08–base0F are legible on base00. It says
# nothing about base01/base02. The old `directory` (fg base0E on bg base01)
# and `nix_shell` (fg base0D on bg base02) pills relied on a guarantee that
# doesn't exist — fine under curated tokyo-night, washed out under a matugen
# palette derived from an arbitrary wallpaper. Colored text on the terminal
# background is the only combination the palette actually promises.
{lib}: rec {
  mkStarshipSettings = wh: {
    # ── Layout ──────────────────────────────────────────────────────────
    add_newline = true;

    format = lib.concatStrings [
      "$os"
      "$directory"
      "$git_branch"
      "$git_state"
      "$git_status"
      "$nix_shell"
      "\${custom.tool}"
      "$package"
      "$fill"
      "$cmd_duration"
      "$jobs"
      "$time"
      "$line_break"
      "$status"
      "$character"
    ];

    # `fill` pads the gap to the terminal edge. Space keeps the line
    # copy-clean; swap to "·" or "─" (dimmed) if you want a visible rule.
    fill = {
      symbol = " ";
      style = "fg:${wh.base02}";
    };

    # ── OS ──────────────────────────────────────────────────────────────
    os = {
      disabled = false;
      symbols.NixOS = " ";
      style = "bold fg:${wh.base0D}";
      format = "[$symbol]($style)";
    };

    # ── Directory ───────────────────────────────────────────────────────
    directory = {
      style = "bold fg:${wh.base0D}";
      format = "[$path]($style)[$read_only]($read_only_style) ";
      truncation_length = 3;
      truncation_symbol = "…/";
      truncate_to_repo = true;
      read_only = " 󰌾";
      read_only_style = "bold fg:${wh.base08}";
      # Nerd Font (Material Design) only — no color emoji. Emoji come from
      # Noto Color Emoji at a different advance width and baseline than
      # JetBrainsMono Nerd Font, which is what made the old prompt look
      # ragged next to its own icons.
      substitutions = {
        "Documents" = "󰈙";
        "Downloads" = "󰇚";
        "Music" = "󰝚";
        "Pictures" = "󰋩";
        "Videos" = "󰕧";
        "Development" = "󰲋";
        "Projects" = "󰲋";
        ".dotfiles" = "󱄅";
      };
    };

    # ── Git ─────────────────────────────────────────────────────────────
    git_branch = {
      symbol = " ";
      style = "bold fg:${wh.base0E}";
      format = "[$symbol$branch]($style)(:[$remote_branch](fg:${wh.base04})) ";
      truncation_length = 24;
      truncation_symbol = "…";
    };

    git_state = {
      style = "bold fg:${wh.base09}";
      format = "\\([$state( $progress_current/$progress_total)]($style)\\) ";
    };

    # Counters instead of pictograms. `📝 2 📦 1 🗑 3` was three color-emoji
    # fallbacks in a monospace line; `!2 *1 ✘3` is unambiguous, aligns, and
    # survives being pasted into a bug report.
    git_status = {
      style = "bold fg:${wh.base0A}";
      format = "([\\[$all_status$ahead_behind\\]]($style) )";
      conflicted = "=\${count}";
      untracked = "?\${count}";
      modified = "!\${count}";
      staged = "+\${count}";
      renamed = "»\${count}";
      deleted = "✘\${count}";
      stashed = "*\${count}";
      ahead = "⇡\${count}";
      behind = "⇣\${count}";
      diverged = "⇕⇡\${ahead_count}⇣\${behind_count}";
      up_to_date = "";
    };

    # ── Nix shell ───────────────────────────────────────────────────────
    nix_shell = {
      symbol = " ";
      style = "bold fg:${wh.base0C}";
      format = "[$symbol$state( \\($name\\))]($style) ";
      # purity state is hidden — "impure" reads as noise next to git status
      impure_msg = "";
      pure_msg = "";
      unknown_msg = "";
      heuristic = true;
    };

    # ── Exit status ─────────────────────────────────────────────────────
    # Sits after $line_break, immediately left of ❯, so a failure reads as
    # part of the prompt character rather than trailing the directory line.
    status = {
      disabled = false;
      symbol = "✘";
      not_executable_symbol = "🚫";
      not_found_symbol = "󰍉";
      # Ctrl+C (SIGINT) is normal usage, not an error — render nothing for it.
      # $signal_name is dropped from the format so "INT" doesn't appear either;
      # real signals keep their icon (󰈸), exit codes keep ✘ + common meaning.
      sigint_symbol = "";
      signal_symbol = "󰈸";
      map_symbol = true;
      style = "bold fg:${wh.base08}";
      format = "[$symbol$common_meaning$maybe_int]($style) ";
    };

    jobs = {
      symbol = "󰑮 ";
      style = "bold fg:${wh.base0A}";
      format = "[$symbol$number]($style) ";
      number_threshold = 1;
      symbol_threshold = 1;
    };

    # ── Runtime tool (single slot, priority-ordered) ──────────────────────
    # Native runtime modules each render independently, so a bun project
    # (which also has package.json) showed BOTH nodejs and bun. One custom
    # module with a priority script shows only the top tool:
    #   bun > nodejs > python > golang > rust > c
    # One shell invocation per prompt; prints nothing (and hides) when no
    # tool matches. Detection mirrors each native module's detect_files
    # (the starship scan runs in-process — no shell spawn when no tool
    # files are present). shell is forced to POSIX sh because starship
    # otherwise runs the command via STARSHIP_SHELL (fish), which cannot
    # parse the POSIX script below.
    custom = {
      tool = {
        shell = "sh";
        detect_files = [
          "bun.lockb"
          "bun.lock"
          "bunfig.toml"
          "package.json"
          ".node-version"
          ".nvmrc"
          "pyproject.toml"
          "requirements.txt"
          "Pipfile"
          "poetry.lock"
          "uv.lock"
          "go.mod"
          "Cargo.toml"
          "Makefile"
          "CMakeLists.txt"
        ];
        command = ''
          if [ -f bun.lockb ] || [ -f bun.lock ] || [ -f bunfig.toml ]; then
            v="$(bun --version 2>/dev/null)" || exit 0
            [ -n "$v" ] || exit 0
            printf '%s v%s' "󰛦" "$v"
            exit 0
          fi
          if [ -f package.json ] || [ -f .node-version ] || [ -f .nvmrc ]; then
            v="$(node --version 2>/dev/null | sed 's/^v//')" || exit 0
            [ -n "$v" ] || exit 0
            printf '%s v%s' "󰎙" "$v"
            exit 0
          fi
          if [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f Pipfile ] || [ -f poetry.lock ] || [ -f uv.lock ]; then
            v="$(python --version 2>/dev/null | awk '{print $2}')" || exit 0
            [ -n "$v" ] || exit 0
            printf '%s v%s' "" "$v"
            exit 0
          fi
          if [ -f go.mod ]; then
            v="$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')" || exit 0
            [ -n "$v" ] || exit 0
            printf '%s v%s' "" "$v"
            exit 0
          fi
          if [ -f Cargo.toml ]; then
            v="$(rustc --version 2>/dev/null | awk '{print $2}')" || exit 0
            [ -n "$v" ] || exit 0
            printf '%s v%s' "" "$v"
            exit 0
          fi
          if [ -f Makefile ] || [ -f CMakeLists.txt ]; then
            v="$(cc --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" || exit 0
            [ -n "$v" ] || exit 0
            printf '%s v%s' "" "$v"
            exit 0
          fi
        '';
        style = "bold fg:${wh.base0F}";
        format = "[$output]($style) ";
      };
    };
    package = {
      symbol = "󰏗 ";
      style = "fg:${wh.base04}";
      format = "[$symbol$version]($style) ";
    };

    # ── Right block (line 1, via $fill) ─────────────────────────────────
    cmd_duration = {
      min_time = 2000;
      show_milliseconds = false;
      style = "bold fg:${wh.base0A}";
      format = "[󰔚 $duration]($style) ";
    };

    time = {
      disabled = false;
      time_format = "%R";
      style = "fg:${wh.base04}";
      format = "[ $time]($style)";
    };

    # ── Character ───────────────────────────────────────────────────────
    character = {
      success_symbol = "[❯](bold fg:${wh.base0B})";
      error_symbol = "[❯](bold fg:${wh.base08})";
      vimcmd_symbol = "[❮](bold fg:${wh.base0E})";
      vimcmd_replace_symbol = "[❮](bold fg:${wh.base09})";
      vimcmd_visual_symbol = "[❮](bold fg:${wh.base0A})";
    };

    # ── Off ─────────────────────────────────────────────────────────────
    aws.disabled = true;
    gcloud.disabled = true;
    openstack.disabled = true;
    azure.disabled = true;
    battery.disabled = true;
    hostname.ssh_only = true;
    username.show_always = false;
  };
}
