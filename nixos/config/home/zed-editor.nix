{
  pkgs,
  lib,
  opts,
  config,
  ...
}: let
  realZed = pkgs.zed-editor;
  guiLauncher = pkgs.callPackage ./gui-session/package.nix {
    mango = config.wayland.windowManager.mango.package;
  };
  # Server terminals outlive Mango. Start the GUI in the live desktop's service
  # lifetime instead of inspecting or killing another Zed process. Desktop
  # hosts, including the GS65, keep the upstream package unchanged.
  launcher = pkgs.writeShellScript "zed-editor-session-launch" ''
    wait_args=()
    for arg in "$@"; do
      case "$arg" in
        --) break ;;
        -h|--help|-v|--version) exec ${lib.getExe realZed} "$@" ;;
        -w|--wait|--foreground) wait_args=(--wait) ;;
      esac
    done
    exec ${lib.getExe guiLauncher} "''${wait_args[@]}" ${lib.getExe realZed} "$@"
  '';
  sessionZed = pkgs.symlinkJoin {
    name = "zed-editor-session-${lib.getVersion realZed}";
    paths = [realZed];
    postBuild = ''
      rm "$out/bin/zeditor"
      ln -s ${launcher} "$out/bin/zeditor"
    '';
  };
in {
  programs.zed-editor = {
    enable = true;
    package =
      if opts.headless
      then sessionZed
      else realZed;
    extensions = [
      "nix"
      "toml"
      "elixir"
      "make"
      "svelte"
      "git-firefly"
      "astro"
      "gdscript"
      "html"
      "codebook"
      # "deno" is removed; Zed will default to the standard TS LSP
      # "biome" used to be left out on the theory that Zed "handled" it. Zed
      # resolved both the project-local biome and its own bundled copy, and the
      # log carried "duplicate textDocument/formatting registration
      # biome_formatting". Declaring it here gives exactly one, managed server.
      "biome"
    ];

    userSettings =
      {
        # ── Remote development ─────────────────────────────────────────────────
        # (declared at the end of this attrset, with `//`, because it is
        # conditional on the host not being headless)

        # --- AI Assistant and Model Configuration ---
        # context_servers = {
        #   mcp-server-firecrawl = {
        #     settings = {
        #       firecrawl_api_key = secrets.FIRECRAWL_API_KEY;
        #     };
        #   };
        #   mcp-server-brave-search = {
        #     settings = {
        #       brave_api_key = secrets.BRAVE_SEARCH_API_KEY;
        #     };
        #   };
        #   mcp-server-github = {
        #     settings = {
        #       github_personal_access_token = secrets.GITHUB_PERSONAL_ACCESS_TOKEN;
        #     };
        #   };

        #   "godot" = {
        #     "command" = "node";
        #     "args" = ["/absolute/path/to/godot-mcp/build/index.js"];
        #     "env" = {
        #       "DEBUG" = "true";
        #     };
        #   };
        # };

        agent = {
          default_profile = "ask";
          play_sound_when_agent_done = "always"; # <-- FIXED DEPRECATION: Was previously `true`
          notify_when_agent_waiting = "all_screens";
          enabled = true;
          button = true;
          dock = "right";
          single_file_review = true;

          tool_permissions = {
            default = "allow";
          };

          # 1. Main Chat Panel
          default_model = {
            provider = "openrouter";
            model = "openrouter/free";
            enable_thinking = true;
          };

          # 2. Git Commit Message Generation
          commit_message_model = {
            provider = "openrouter";
            model = "openrouter/free";
          };

          # 3. Inline Assistant (Ctrl+Enter inside the editor)
          inline_assistant_model = {
            provider = "openrouter";
            model = "openrouter/free";
          };

          # 4. Terminal Assistant (Ctrl+Enter inside the integrated terminal)
          terminal_assistant_model = {
            provider = "openrouter";
            model = "openrouter/free";
          };
        };

        # --- General Editor Settings ---
        load_direnv = "shell_hook";
        base_keymap = "VSCode";
        # Palette-generated theme (theme/lib.nix mkZedTheme →
        # ~/.config/zed/themes/dynamic.json). Static palette on rebuild,
        # wallpaper palette in dynamic mode; applies on next launch.
        theme = {
          mode = "dark";
          light = "One Light";
          # Zed resolves an installed theme by FILE STEM, not by the "name" field
          # inside it. The generated theme is dynamic.json and its internal name
          # is "Dynamic", so asking for "Dynamic" logged: theme not found: Dynamic.
          dark = "dynamic";
        };

        node = {
          path = lib.getExe pkgs.nodejs;
          npm_path = lib.getExe' pkgs.nodejs "npm";
        };

        auto_update = false;
        telemetry = {
          diagnostics = false;
          metrics = false;
        };

        # --- Font and Appearance ---
        buffer_font_family = "JetBrainsMono Nerd Font Mono";
        buffer_font_size = 16;
        # OpenType feature TAGS with a value. `ligatures` is not a tag; Zed
        # rejected it on every settings parse ("Incorrect font feature tag:
        # ligatures"). `calt` is the contextual-alternates tag that ligatures use.
        buffer_font_features = {calt = true;};

        ui_font_family = "JetBrainsMono Nerd Font Mono";
        ui_font_size = 16;
        ui_font_features = {calt = true;};

        # --- Transparency / Blur ---
        # Transparent: backgrounds, title bar, tab bar
        # Opaque: modals, tooltips, popovers, search (readability)
        # "experimental.theme_overrides" = {
        #   # --- Editor (transparent) ---
        #   "background.appearance" = "blurred";
        #   "background" = "#00000030";
        #   "editor.background" = "#00000030";
        #   "editor.gutter.background" = "#00000030";
        #   "editor.subheader.background" = "#00000030";
        #   "editor.active_line.background" = "#2f343e80";

        #   # --- Chrome / sidebar (transparent) ---
        #   "title_bar.background" = "#00000030";
        #   "tab_bar.background" = "#00000020";
        #   "tab.active_background" = "#00000040";
        #   "tab.inactive_background" = "#00000000";
        #   "toolbar.background" = "#00000020";
        #   "status_bar.background" = "#00000040";

        #   # --- Terminal (transparent) ---
        #   "terminal.background" = "#00000030";

        #   # --- Panel / dock (slightly transparent) ---
        #   "panel.background" = "#00000060";

        #   # --- Modals & popovers (OPAQUE — must be readable) ---
        #   "elevated_surface.background" = "#282c33ff";
        #   "surface.background" = "#282c33ff";
        #   "element.background" = "#2e343eff";
        #   "element.hover" = "#363c46ff";
        #   "element.active" = "#454a56ff";
        #   "element.selected" = "#454a56ff";

        #   # --- Scrollbar (keep visible) ---
        #   "scrollbar.thumb.background" = "#c8ccd44c";
        #   "scrollbar.track.background" = "#00000000";
        # };

        show_whitespaces = "all";

        scrollbar = {
          show = "always";
        };

        # --- Formatting ---
        format_on_save = "on";
        source_actions_on_save = [];

        # --- Diagnostics and Linting ---
        spelling = {
          user_words = ["dotfiles" "nixos" "nswitchu" "unfavourite" "onready"];
        };

        # --- Integrated Terminal ---
        terminal = {
          alternate_scroll = "off";
          copy_on_select = true;
          dock = "bottom";
          detect_venv = {
            on = {
              directories = [".env" "env" ".venv" "venv"];
              activate_script = "default";
            };
          };
          env = {};
          font_family = "JetBrainsMono Nerd Font Mono";
          font_features = {calt = true;};
          font_size = 16;
          line_height = "comfortable";
          option_as_meta = false;
          button = false;
          shell = "system";
          working_directory = "current_project_directory";
        };

        # --- Language Server Protocol (LSP) Configurations ---
        lsp = {
          biome = {
            settings = {
              require_config_file = true;
            };
          };
          nix = {
            # Zed's nix extension runs `nil`, not `nixd`. `path_lookup` found
            # nothing (nil is not in the store), so every Nix file logged:
            #   Failed to start language server "nil": nil must be installed
            #   manually.
            # The settings block below used to configure `nixd`, which this
            # extension no longer speaks, so it was dead config; nixd's
            # sema-escaping-with suppression has no nil equivalent and is gone.
            # Nix files are still formatted, by languages.Nix.formatter below.
            binary = {
              path = "${pkgs.nil}/bin/nil";
            };
          };
          gdscript = {
            binary = {
              arguments = ["127.0.0.1" "6005"];
            };
          };
        };

        # --- Language-Specific Settings ---
        languages = {
          Nix = {
            format_on_save = "on";
            formatter = {
              external = {
                command = "${pkgs.alejandra}/bin/alejandra";
                arguments = ["-"];
              };
            };
          };
          GDScript = {
            format_on_save = "on";
            formatter = {
              external = {
                command = "gdformat";
                arguments = ["-"];
              };
            };
          };
          Dart = {
            format_on_save = "on";
            preferred_line_length = 80;
          };

          JSON = {
            formatter = {language_server = {name = "biome";};};
          };
          JSONC = {
            formatter = {language_server = {name = "biome";};};
          };
          TSX = {
            formatter = {language_server = {name = "biome";};};
            code_actions_on_format = {
              "source.fixAll.biome" = true;
              "source.organizeImports.biome" = true;
            };
          };
          JavaScript = {
            formatter = {language_server = {name = "biome";};};
            code_actions_on_format = {
              "source.fixAll.biome" = true;
              "source.organizeImports.biome" = true;
            };
          };
          TypeScript = {
            formatter = {language_server = {name = "biome";};};
            code_actions_on_format = {
              "source.fixAll.biome" = true;
              "source.organizeImports.biome" = true;
            };
          };
          Astro = {
            formatter = {language_server = {name = "biome";};};
          };
          Svelte = {
            formatter = {language_server = {name = "biome";};};
          };
        };

        # --- Custom Keybindings ---
        keymap = [
          {
            context = "Editor && !VimControl && !menu";
            bindings = {
              "ctrl-q" = "editor::ToggleComment";
              "ctrl-alt-g" = ["agent::NewExternalAgentThread" {"agent" = "gemini";}];
            };
          }
        ];
        # ── Remote development ───────────────────────────────────────────────────
        #
        # Zed runs its UI on THIS machine and a HEADLESS server on the Legion:
        # language servers, tasks, terminals and the agent panel run over there,
        # over SSH. Unsaved edits are held locally.
        #
        # This does NOT use the Legion's `zeditor`. Zed downloads and keeps its
        # own server in ~/.zed_server on the far end, version-matched to the
        # local Zed, so the session-wrapped package that `role = "server"` selects
        # (see `sessionZed` above) is irrelevant to this path. That was worth
        # checking rather than assuming, because ns-gui hard-fails without a live
        # desktop session and it would have looked like a blocker.
        #
        # DECLARED IN NIX, NOT THROUGH THE REMOTE PROJECTS DIALOG. home-manager
        # writes ~/.config/zed/settings.json wholesale, keeping the previous file
        # as settings.json.bak-<timestamp>. There is a stale .bak on this host
        # right now, so this has already happened once. Anything added through
        # the UI is discarded at the next activation without warning, which is
        # the kind of thing that works in the demo and is gone on Monday.
        #//
        #// Only a desktop host is a CLIENT here; the Legion is the server for this
        #// arrangement, and offering it an entry for itself would be noise.
        #//
        #// What does NOT travel: the settings above. `nil` and `alejandra` are
        #// named by STORE PATH, resolved on whichever machine reads the file. Zed
        #// propagates extensions to the remote but not main settings files, so in
        #// a remote project the nix LSP and the Nix formatter will look for MSI
        #// paths on the Legion and quietly not start. Fixing that properly means
        #// moving those two into server settings or .zed/settings.json, which is
        #// a separate change and is NOT made here — it would alter formatting on
        #// the MSI too, and that is a decision for the operator, not a side effect
        #// of adding a remote server.
        #//
        #// Mentally separate the three: LOCAL settings are the UI (fonts, theme,
        #// keymap), SERVER settings are paths to language servers and formatters,
        #// and PROJECT settings (.zed/settings.json) are per-repository.
      }
      // lib.optionalAttrs (!opts.headless) {
        ssh_connections = [
          {
            # "legion", not an address. The Host legion alias is generated by
            # config/home/travel.nix with Port 2222, User, and the PINNED host
            # key, and Zed shells out to ssh and inherits ~/.ssh/config. An
            # address here would bypass the pin and fall back to TOFU, which
            # is exactly the failure known_hosts.travel exists to prevent.
            host = opts.travel.serverHost;

            # Shown in the picker. The alias alone does not say which of several
            # machines is which once two are connected.
            nickname = "${opts.travel.serverHost} (basement server)";

            # A SPECIFIC directory. Never ~ and never the Development tree:
            # Zed warns that very large directories open poorly, and on the
            # Legion ~ is 565G and passion/ is 252G. The failure mode is an
            # editor that takes a minute to appear, which reads as a hang.
            # Add more entries here rather than broadening this one.
            projects = [
              {
                paths = ["${config.home.homeDirectory}/.dotfiles"];
              }
            ];

            # Fetch the server through THIS machine instead of letting the
            # Legion pull it from zed.dev. The Legion reaches the internet
            # today (verified), but it is an unattended basement box: if its
            # egress is ever restricted, the direct download is the part that
            # breaks, and it breaks as a confusing connection error rather
            # than anything that names the network. One upload at connection
            # time is cheap for that.
            upload_binary_over_ssh = true;
          }
        ];
      };
  };
}
