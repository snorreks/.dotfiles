# nixos/config/home/fish/functions/screenshot_edit.fish
function screenshot_edit
    grimblast --notify --cursor save area ~/Pictures/$(date +'%Y-%m-%d-At-%Ih%Mm%Ss').png
end
