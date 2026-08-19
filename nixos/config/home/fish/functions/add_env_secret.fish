function add_env_secret --description "Add/update an encrypted secret and wire it up as an env var (secrets.yaml, sops.nix, variables.nix)"
    set -l dotfiles_dir "$HOME/.dotfiles/nixos"
    set -l secrets_file "$dotfiles_dir/secrets.yaml"
    set -l env_secrets_file "$dotfiles_dir/config/home/env-secrets.nix"

    # 1. Sanity checks
    if not command -v sops >/dev/null
        echo (set_color red)"❌ Error: 'sops' not found. Install it or run: nix-shell -p sops"(set_color normal)
        return 1
    end

    if not command -v jq >/dev/null
        echo (set_color red)"❌ Error: 'jq' not found. Install it or run: nix-shell -p jq"(set_color normal)
        return 1
    end

    if not test -f "$secrets_file"; or not test -f "$env_secrets_file"
        echo (set_color red)"❌ Error: Could not locate dotfiles at $dotfiles_dir"(set_color normal)
        return 1
    end

    # 2. Get variable name
    set -l var_name ""
    if test (count $argv) -gt 0
        set var_name $argv[1]
    else
        read -P (set_color cyan)"🔑 Enter Secret Name (e.g. MY_API_KEY): "(set_color normal) var_name
    end

    set var_name (string upper (string trim -- $var_name))

    if test -z "$var_name"
        echo (set_color red)"❌ Secret name cannot be empty."(set_color normal)
        return 1
    end

    if not string match -qr '^[A-Z_][A-Z0-9_]*$' -- $var_name
        echo (set_color red)"❌ '$var_name' is not a valid env var name (use A-Z, 0-9, _)."(set_color normal)
        return 1
    end

    set -l already_declared 0
    if grep -q "name = \"$var_name\";" "$env_secrets_file"
        set already_declared 1
        echo (set_color yellow)"ℹ '$var_name' is already declared — this will just update its encrypted value."(set_color normal)
    end

    # 3. Get secret value (hidden input)
    read -s -P (set_color cyan)"🔒 Enter Secret Value for $var_name: "(set_color normal) var_val
    echo ""

    if test -z "$var_val"
        echo (set_color red)"❌ Secret value cannot be empty."(set_color normal)
        return 1
    end

    # 4. Optional aliases (only meaningful for a new declaration)
    set -l alias_names
    if test $already_declared -eq 0
        set -l aliases_raw ""
        read -P (set_color cyan)"➕ Extra alias env var names, comma-separated (optional, e.g. GH_TOKEN): "(set_color normal) aliases_raw
        for a in (string split ',' -- $aliases_raw)
            set -l a (string upper (string trim -- $a))
            if test -n "$a"
                set -a alias_names $a
            end
        end
    end

    echo (set_color yellow)"⏳ Processing..."(set_color normal)

    # 5. Encrypt the value into secrets.yaml.
    # --value-stdin avoids putting the secret in the process arg list (visible via `ps`);
    # jq -Rs . JSON-encodes it, as required by `sops set`'s value format.
    printf '%s' "$var_val" | jq -Rs . | sops set --value-stdin "$secrets_file" "[\"$var_name\"]"
    if test $status -eq 0
        echo (set_color green)"  ✔ Updated $secrets_file"(set_color normal)
    else
        echo (set_color red)"  ❌ Failed to update $secrets_file"(set_color normal)
        return 1
    end

    # 6. Append the declaration to env-secrets.nix — the single source of
    #    truth that sops.nix and variables.nix both generate from.
    if test $already_declared -eq 0
        set -l lines (cat "$env_secrets_file")
        set -l n (count $lines)

        if test "$lines[$n]" != "]"
            echo (set_color red)"  ❌ $env_secrets_file doesn't end with a bare ']' — please add the entry manually:"(set_color normal)
            echo "      { name = \"$var_name\"; }"
            return 1
        end

        set -l entry_lines
        if test (count $alias_names) -gt 0
            set -l alias_list (string join ' ' (for a in $alias_names; echo "\"$a\""; end))
            set entry_lines \
                "  {" \
                "    name = \"$var_name\";" \
                "    aliases = [$alias_list];" \
                "  }"
        else
            set entry_lines "  {name = \"$var_name\";}"
        end

        set -l new_lines $lines[1..(math $n - 1)]
        set -a new_lines $entry_lines
        set -a new_lines $lines[$n]

        printf '%s\n' $new_lines >"$env_secrets_file"

        if command -v alejandra >/dev/null
            alejandra -q "$env_secrets_file"
        end

        echo (set_color green)"  ✔ Declared $var_name in $env_secrets_file"(set_color normal)
        if test (count $alias_names) -gt 0
            echo (set_color green)"    aliases: $alias_names"(set_color normal)
        end
        echo (set_color green)"    → automatically picked up by sops.nix (sops.secrets + secrets-env) and variables.nix (sessionVariables)"(set_color normal)
    end

    # 7. Prompt to rebuild system
    echo ""
    echo (set_color green)"✅ Secret '$var_name' successfully configured!"(set_color normal)
    read -P (set_color magenta)"🚀 Rebuild NixOS now? (y/N): "(set_color normal) confirm

    if string match -iq "y*" -- $confirm
        echo (set_color yellow)"Running: nh os switch $dotfiles_dir"(set_color normal)
        nh os switch "$dotfiles_dir"
    else
        echo (set_color blue)"Skipped rebuild. Run 'nh os switch ~/.dotfiles/nixos' when ready."(set_color normal)
    end
end
