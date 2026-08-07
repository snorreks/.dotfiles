

function wifi --description "Connect to a WiFi network"
    echo "Scanning for WiFi networks..."
    # Fetch networks and sort by signal strength (field 3 in descending order)
    set -l networks (nmcli -t -f IN-USE,SSID,SECURITY,SIGNAL device wifi list | sort -t: -k4 -r | sed '/^--/d')
    set -l count 1

    for network in $networks
        set -l ssid (echo $network | cut -d ':' -f2)
        set -l security (echo $network | cut -d ':' -f3)
        set -l signal (echo $network | cut -d ':' -f4)
        echo "$count. $ssid (Security: $security, Signal: $signal%)"
        set count (math $count + 1)
    end

    echo "Select the number of the WiFi network you wish to connect to:"
    read -l selection

    # Validate selection
    if test $selection -gt (count $networks) || test $selection -lt 1
        echo "Invalid selection. Please run the command again and select a valid number."
        return
    end

    # Extracting SSID and security from the user's selection
    set -l selected_network (echo $networks[$selection] | cut -d ':' -f2)
    set -l wifi_security (echo $networks[$selection] | cut -d ':' -f3)

    if test "$wifi_security" = wpa2-enterprise -o "$wifi_security" = 802-1x
        # Connect to the WiFi network with WPA Enterprise settings
        echo "Enter the username for $selected_network:"
        read -l username
        echo "Enter the password for $selected_network:"
        read -l password
        nmcli device wifi connect "$selected_network" \
            password "$password" \
            username "$username" \
            802-1x true
        elif test "$wifi_security" != none
        # Connect to the WiFi network with a password
        echo "Enter the password for $selected_network:"
        read -l password
        nmcli device wifi connect "$selected_network" password "$password"
    else
        # Connect to the WiFi network without a password
        nmcli device wifi connect "$selected_network"
    end

    echo "Connecting to $selected_network..."
end
