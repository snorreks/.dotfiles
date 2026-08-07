function fetch_sops_key --description "Restore Sops Age key from Bitwarden vault"
    set -l key_path ~/.config/sops/age/keys.txt

    if test -f $key_path
        echo "✅ Age key already exists at $key_path"
        return 0
    end

    if not command -v bw > /dev/null
        echo "❌ Bitwarden CLI (bw) not found. Install it with: nix-shell -p bitwarden-cli"
        return 1
    end

    echo "🔐 Logging into Bitwarden..."
    bw login

    if test $status -ne 0
        echo "❌ Bitwarden login failed"
        return 1
    end

    set -gx BW_SESSION (bw unlock --raw)

    echo "📥 Fetching Age key from vault..."
    mkdir -p ~/.config/sops/age
    bw get notes "sops-age-key" > $key_path
    chmod 700 ~/.config/sops/age
    chmod 600 $key_path

    echo "✅ Age key successfully restored to $key_path"
end
