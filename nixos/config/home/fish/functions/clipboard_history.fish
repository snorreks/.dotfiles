function cliphist_control
    set ScrDir (dirname (realpath (status filename)))
    global_control

    set roconf "~/.config/rofi/clipboard.rasi"

    set pos "window {location: center;}"

    set wind_border (math "$wm_border * 3 / 2")
    set elem_border (test $wm_border -eq 0; and echo "5"; or echo $wm_border)
    set r_override "window {border: {$wm_width}px; border-radius: {$wind_border}px;} entry {border-radius: {$elem_border}px;} element {border-radius: {$elem_border}px;}"
    set fnt_override "configuration {font: \"JetBrainsMono Nerd Font {$fnt_override}\";}"

    switch $argv[1]
        case 'c'
            cliphist list | fuzzel --dmenu -theme-str "entry { placeholder: \"Copy...\";} {$pos} {$r_override}" -theme-str "{$fnt_override}" -config $roconf | cliphist decode | wl-copy
        case 'd'
            cliphist list | fuzzel --dmenu -theme-str "entry { placeholder: \"Delete...\";} {$pos} {$r_override}" -theme-str "{$fnt_override}" -config $roconf | cliphist delete
        case 'w'
            if test (echo -e "Yes\nNo" | fuzzel --dmenu -theme-str "entry { placeholder: \"Clear Clipboard History?\";} {$pos} {$r_override}" -theme-str "{$fnt_override}" -config $roconf) = "Yes"
                cliphist wipe
            end
        case '*'
            echo "cliphist.fish [action]"
            echo "c :  cliphist list and copy selected"
            echo "d :  cliphist list and delete selected"
            echo "w :  cliphist wipe database"
            return 1
    end
end
