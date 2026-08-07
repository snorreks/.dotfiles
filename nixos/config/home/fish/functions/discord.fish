function discord --description "Discord launcher — auto-repairs module symlinks broken by nix GC"
    set -l real_discord ""
    # Find real Discord binary: check nix profile symlink first
    set -l prof "/etc/profiles/per-user/$USER/bin/discord"
    if test -L "$prof"
        set real_discord (readlink -f "$prof" 2>/dev/null)
        test -x "$real_discord" || set real_discord ""
    end
    # Fallback: scan PATH
    if test -z "$real_discord"
        for dir in $PATH
            test "$dir" = "$HOME/.dotfiles/bin" && continue
            if test -x "$dir/discord"
                set real_discord (readlink -f "$dir/discord")
                break
            end
        end
    end
    if test -z "$real_discord"
        echo "discord: could not find real Discord binary" >&2
        return 1
    end

    # Derive the Nix store path
    set -l store_dir (dirname (dirname (dirname "$real_discord")))
    set -l modules_src "$store_dir/opt/Discord/modules"
    if test ! -d "$modules_src"
        exec "$real_discord" $argv
    end

    # Repair dead symlinks in ~/.config/discord/<version>/modules/
    for version_dir in $HOME/.config/discord/*/modules/
        test -d "$version_dir" || continue
        for symlink in $version_dir/*
            test -L "$symlink" || continue
            if test ! -e "$symlink"
                set -l modname (basename "$symlink")
                set -l new_target "$modules_src/$modname"
                if test -d "$new_target"
                    rm "$symlink"
                    ln -s "$new_target" "$symlink"
                    echo "discord: repaired dead symlink: $modname" >&2
                end
            end
        end
    end

    exec "$real_discord" $argv
end
