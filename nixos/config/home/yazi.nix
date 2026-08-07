{opts, ...}: {
  programs.yazi = {
    enable = true;
    shellWrapperName = "y";
    enableFishIntegration = false;

    keymap = {
      mgr = {
        prepend_keymap = [
          {
            on = ["e"];
            run = "shell '${opts.defaultFileManager} \"$PWD\"' --orphan";
            desc = "Open current directory in file manager";
          }
        ];
      };
    };
    settings = {
      opener = {
        unarchive = [
          {
            run = "bsdtar -xf \"$@\"";
            desc = "Extract here";
          }
        ];
        text = [
          {
            run = "${opts.defaultEditor} \"$@\"";
            block = true;
          }
        ];
        video = [
          {
            run = "mpv \"$@\"";
            orphan = true;
          }
        ];
        browser = [
          {
            run = "${opts.defaultBrowser} \"$@\"";
            orphan = true;
          }
        ];
        "file-manager" = [
          {
            run = "${opts.defaultFileManager} \"$@\"";
            orphan = true;
          }
        ];
      };
      open = {
        rules =
          let
            unarchiveMimes = [
              "application/x-rar-compressed"
              "application/x-7z-compressed"
              "application/x-tar"
              "application/x-bzip2"
              "application/x-gzip"
              "application/x-xz"
              "application/x-lzma"
              "application/x-lzip"
              "application/x-lzop"
              "application/x-compress"
              "application/x-iso9660-image"
              "application/vnd.ms-cab-compressed"
              "application/x-deb"
              "application/x-rpm"
              "application/x-zstd-compressed"
            ];
          in
            builtins.concatLists (map (mime: [
                {
                  mime = mime;
                  use = "unarchive";
                }
              ])
              unarchiveMimes)
            ++ [
              # --- Directories: Enter → file manager; use l/h to navigate ---
              {
                mime = "inode/directory";
                use = "file-manager";
              }
              # --- Code / text files → editor ---
              {
                url = "*.{ts,tsx,js,jsx,mjs,cjs,go,rs,py,rb,nix,sh,bash,zsh,fish,lua,vim,toml,yaml,yml,json,jsonc,css,scss,less,sql,graphql,md,mdx,txt,Dockerfile,Makefile,env,env.example}";
                use = "text";
              }
              # --- Web files → browser (fall back to editor) ---
              {
                url = "*.{html,htm,xhtml}";
                use = ["browser" "text"];
              }
              {
                url = "*.pdf";
                use = "browser";
              }
            ];
      };
    };
  };
}
