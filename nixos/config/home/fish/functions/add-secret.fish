function add-secret --description "Add a new encrypted secret to sops and update sops.nix"
    set -l dotfiles_dir "$HOME/.dotfiles/nixos"
    set -l secrets_file "$dotfiles_dir/secrets.yaml"
    set -l sops_nix_file "$dotfiles_dir/config/home/sops.nix"

    # 1. Sanity check: Ensure sops and python3 are available
    if not command -v sops >/dev/null
        echo (set_color red)"❌ Error: 'sops' not found. Install it or run: nix-shell -p sops"(set_color normal)
        return 1
    end

    if not test -f "$secrets_file"; or not test -f "$sops_nix_file"
        echo (set_color red)"❌ Error: Could not locate dotfiles at $dotfiles_dir"(set_color normal)
        return 1
    end

    # 2. Get Variable Name
    set -l var_name ""
    if test (count $argv) -gt 0
        set var_name $argv[1]
    else
        read -P (set_color cyan)"🔑 Enter Secret Name (e.g. MY_API_KEY): "(set_color normal) var_name
    end

    # Clean and uppercase variable name
    set var_name (string upper (string trim $var_name))

    if test -z "$var_name"
        echo (set_color red)"❌ Secret name cannot be empty."(set_color normal)
        return 1
    end

    # 3. Get Secret Value (Hidden Input)
    read -s -P (set_color cyan)"🔒 Enter Secret Value for $var_name: "(set_color normal) var_val
    echo ""

    if test -z "$var_val"
        echo (set_color red)"❌ Secret value cannot be empty."(set_color normal)
        return 1
    end

    echo (set_color yellow)"⏳ Processing..."(set_color normal)

    # 4. Add/Update secret in secrets.yaml using sops
    sops set "[\"$var_name\"] \"$var_val\"" "$secrets_file"
    if test $status -eq 0
        echo (set_color green)"  ✔ Updated $secrets_file"(set_color normal)
    else
        echo (set_color red)"  ❌ Failed to update $secrets_file"(set_color normal)
        return 1
    end

    # 5. Automatically insert declaration into sops.nix via python3
    python3 -c "
import re, sys

sops_nix_file = sys.argv[1]
var_name = sys.argv[2]

with open(sops_nix_file, 'r') as f:
    content = f.read()

# Insert into sops.secrets block
if f'{var_name} = {{}}' not in content:
    content = re.sub(
        r'(secrets\s*=\s*\{[^}]*?)(\n\s*\};)',
        rf'\1\n      {var_name} = {{}};\2',
        content,
        count=1
    )

# Insert into secrets-env template content
if f'export {var_name}=' not in content:
    export_line = f'          export {var_name}=\"\${{config.sops.placeholder.{var_name}}}\"'
    content = re.sub(
        r'(\"secrets-env\"\s*=\s*\{[\s\S]*?content\s*=\s*\'\'[\s\S]*?)(\n\s*\'\';)',
        rf'\1{export_line}\2',
        content,
        count=1
    )

with open(sops_nix_file, 'w') as f:
    f.write(content)
" "$sops_nix_file" "$var_name"

    if test $status -eq 0
        echo (set_color green)"  ✔ Updated $sops_nix_file"(set_color normal)
    else
        echo (set_color red)"  ❌ Failed to update $sops_nix_file — please add $var_name manually"(set_color normal)
    end

    # 6. Prompt to rebuild system
    echo (set_color green)"\n✅ Secret '$var_name' successfully configured!"(set_color normal)
    read -P (set_color magenta)"🚀 Rebuild NixOS now? (y/N): "(set_color normal) confirm

    if string match -iq "y*" -- $confirm
        echo (set_color yellow)"Running: nh os switch $dotfiles_dir"(set_color normal)
        nh os switch "$dotfiles_dir"
    else
        echo (set_color blue)"Skipped rebuild. Run 'nh os switch ~/.dotfiles/nixos' when ready."(set_color normal)
    end
end
