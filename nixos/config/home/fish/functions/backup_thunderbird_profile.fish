function backup_thunderbird_profile --description "Snapshot Thunderbird accounts/auth (not mail) into sops"
    set -l dotfiles_dir "$HOME/.dotfiles/nixos"
    set -l secrets_file "$dotfiles_dir/secrets.yaml"
    set -l secret_key thunderbird_profile_bundle

    if not command -v sops >/dev/null
        echo (set_color red)"❌ 'sops' not found. Run: nix-shell -p sops"(set_color normal)
        return 1
    end

    set -l ini "$HOME/.thunderbird/profiles.ini"
    if not test -f $ini
        echo (set_color red)"❌ No Thunderbird profile found ($ini) — launch Thunderbird at least once first."(set_color normal)
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

    # Account names, servers, polling intervals, saved logins/OAuth tokens,
    # OpenPGP keys, and the address book — deliberately NOT the mail store
    # (ImapMail/, global-messages-db.sqlite) or caches.
    set -l files prefs.js logins.json logins.db key4.db cert9.db pkcs11.txt openpgp.sqlite encrypted-openpgp-passphrase.txt abook.sqlite
    set -l present
    for f in $files
        if test -e "$profile_dir/$f"
            set -a present $f
        end
    end

    if test (count $present) -eq 0
        echo (set_color red)"❌ None of the expected profile files were found — nothing to back up."(set_color normal)
        return 1
    end

    set -l tmpdir (mktemp -d)

    tar -czf "$tmpdir/bundle.tar.gz" -C $profile_dir $present
    base64 -w0 "$tmpdir/bundle.tar.gz" >"$tmpdir/bundle.b64"

    # Decrypt into a scratch path ending in "nixos/secrets.yaml" so it still
    # matches .sops.yaml's path_regex when we re-encrypt it below.
    mkdir -p "$tmpdir/nixos"
    set -l scratch "$tmpdir/nixos/secrets.yaml"

    sops -d $secrets_file >$scratch
    if test $status -ne 0
        echo (set_color red)"❌ Failed to decrypt $secrets_file"(set_color normal)
        rm -rf $tmpdir
        return 1
    end

    # The base64 value can be large — too big to safely pass as a shell/awk
    # argument (ARG_MAX), so awk reads it from the file itself via getline.
    # `sops -d` strips the trailing sops: metadata block entirely (it's not
    # part of the document), so a plain "replace if present, else append at
    # end" is correct — key order doesn't matter in YAML.
    awk -v key="$secret_key" -v valfile="$tmpdir/bundle.b64" '
        BEGIN { getline val < valfile; close(valfile); done = 0 }
        {
            if ($0 ~ "^" key ":") { print key ": \"" val "\""; done = 1; next }
            print
        }
        END { if (!done) print key ": \"" val "\"" }
    ' $scratch >"$scratch.new"
    mv "$scratch.new" $scratch

    if not grep -q "^$secret_key:" $scratch
        echo (set_color red)"❌ Insert failed — not touching $secrets_file."(set_color normal)
        shred -u $scratch 2>/dev/null; or rm -f $scratch
        rm -rf $tmpdir
        return 1
    end

    # Encrypt to a temp file first and round-trip-verify it decrypts cleanly
    # before ever overwriting the real secrets.yaml.
    sops -e $scratch >"$tmpdir/secrets.enc.yaml"
    if test $status -ne 0; or test (wc -l <"$tmpdir/secrets.enc.yaml") -lt 10
        echo (set_color red)"❌ Re-encrypt failed or produced suspiciously short output — not touching $secrets_file."(set_color normal)
        shred -u $scratch 2>/dev/null; or rm -f $scratch
        rm -rf $tmpdir
        return 1
    end

    sops -d "$tmpdir/secrets.enc.yaml" >"$tmpdir/verify.yaml" 2>/dev/null
    if not grep -q "^$secret_key:" "$tmpdir/verify.yaml"
        echo (set_color red)"❌ Round-trip verify failed — not touching $secrets_file."(set_color normal)
        shred -u $scratch $tmpdir/verify.yaml 2>/dev/null; or rm -f $scratch $tmpdir/verify.yaml
        rm -rf $tmpdir
        return 1
    end

    cp "$tmpdir/secrets.enc.yaml" $secrets_file
    shred -u $scratch "$tmpdir/verify.yaml" 2>/dev/null; or rm -f $scratch "$tmpdir/verify.yaml"
    rm -rf $tmpdir

    echo (set_color green)"✔ Backed up: "(string join ", " $present)(set_color normal)
    echo (set_color green)"✔ Saved to '$secret_key' in $secrets_file"(set_color normal)
    echo (set_color blue)"Commit + push secrets.yaml to carry this to a new machine."(set_color normal)
end
