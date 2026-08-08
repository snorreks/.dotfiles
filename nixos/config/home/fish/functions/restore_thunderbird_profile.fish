function restore_thunderbird_profile --description "Restore Thunderbird accounts/auth from the sops backup"
    set -l bundle_path "$HOME/.config/sops/thunderbird-profile-bundle.b64"

    if not test -f $bundle_path
        echo (set_color red)"❌ No decrypted bundle at $bundle_path"(set_color normal)
        echo "Either nothing has been backed up yet (run backup_thunderbird_profile on the"
        echo "old machine first), or sops-nix hasn't deployed it — run nswitchu."
        return 1
    end

    set -l ini "$HOME/.thunderbird/profiles.ini"
    if not test -f $ini
        echo (set_color red)"❌ No Thunderbird profile found ($ini)."(set_color normal)
        echo "Launch Thunderbird once to create a default profile, close it, then re-run this."
        return 1
    end

    set -l profile_rel (awk -F= '
        /^\[/ { sect=$0; path[sect]=""; def[sect]=0 }
        /^Path=/ { path[sect]=$2 }
        /^Default=1/ { def[sect]=1 }
        END {
            for (s in def) if (def[s]==1 && path[s]!="") { print path[s]; found=1 }
            if (!found) for (s in path) if (path[s]!="") { print path[s]; break }
        }
    ' $ini)

    set -l profile_dir "$HOME/.thunderbird/$profile_rel"
    if not test -d $profile_dir
        echo (set_color red)"❌ Could not resolve Thunderbird profile directory ($profile_dir)."(set_color normal)
        return 1
    end

    echo (set_color yellow)"This overwrites account/login/OpenPGP files in $profile_dir"(set_color normal)
    read -P "Continue? (y/N): " confirm
    if not string match -riq 'y(es)?' -- $confirm
        echo "Cancelled."
        return 1
    end

    echo "Quit Thunderbird first if it's running, then press enter to continue."
    read -P "" _

    base64 -d $bundle_path | tar -xzf - -C $profile_dir
    if test $status -ne 0
        echo (set_color red)"❌ Restore failed."(set_color normal)
        return 1
    end

    echo (set_color green)"✔ Restored account settings, polling intervals, saved logins, and OpenPGP keys."(set_color normal)
    echo "Mail itself was never included — Thunderbird will re-sync it from the server."
end
