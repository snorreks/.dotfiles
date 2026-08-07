function brightness_control
    set ScrDir (dirname (realpath (status filename)))
    global_control

    function print_error
        echo "    ./brightnesscontrol.fish <action>"
        echo "    ...valid actions are..."
        echo "        i -- <i>ncrease brightness [+5%]"
        echo "        d -- <d>ecrease brightness [-5%]"
    end

function send_notification
    set brightness (brightnessctl info | grep -oP '(?<=\()\d+(?=%)' | cat)
    set brightinfo (brightnessctl info | awk -F "'" '/Device/ {print $2}')

    # Calculate angle as an integer
    set angle (math "(($brightness + 2) / 5) * 5")

    set ico "~/.config/dunst/icons/vol/vol-$angle.svg"

    # Calculate the bar length as an integer using floor division
    set bar_length (math "$brightness / 15")

    # Ensure bar_length is an integer for string repeat
    set bar_length (math "floor($bar_length)")

    set bar (string repeat -n $bar_length '.')

    notify-send "t2" -i $ico -a "$brightness$bar" "$brightinfo" -r 91190 -t 800
end




function get_brightness
    set -l brightness (brightnessctl -m | grep -o '[0-9]\+%' | string replace '%' '')
    echo $brightness
end


    switch $argv[1]
        case 'i'  # increase the backlight
            if test (get_brightness) -lt 10
                # increase the backlight by 1% if less than 10%
                brightnessctl set +1%
            else
                # increase the backlight by 5% otherwise
                brightnessctl set +5%
            end
            send_notification
        case 'd'  # decrease the backlight
            if test (get_brightness) -le 1
                # avoid 0% brightness
                brightnessctl set 1%
            else if test (get_brightness) -le 10
                # decrease the backlight by 1% if less than 10%
                brightnessctl set 1%-
            else
                # decrease the backlight by 5% otherwise
                brightnessctl set 5%-
            end
            send_notification
        case '*'  # print error
            print_error
    end
end
