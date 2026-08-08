{
  pkgs,
  lib,
  ...
}: {
  programs.zed-editor = {
    enable = true;
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
      # "biome" is assumed to be installed locally or handled by Zed
    ];

    userSettings = {
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
        dark = "Dynamic";
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
      buffer_font_features = {ligatures = true;};

      ui_font_family = "JetBrainsMono Nerd Font Mono";
      ui_font_size = 16;
      ui_font_features = {ligatures = true;};

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
        font_features = {ligatures = true;};
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
          binary = {
            path_lookup = true;
          };
          settings = {
            "nixd" = {
              "formatting" = {
                "command" = ["${pkgs.alejandra}/bin/alejandra"];
              };
              "diagnostic" = {
                "suppress" = ["sema-escaping-with"];
              };
            };
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
    };
  };
}
