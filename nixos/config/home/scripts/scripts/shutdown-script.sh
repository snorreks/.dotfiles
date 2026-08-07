#!/usr/bin/env bash

respond="$(printf '---------------- Yes ----------------\n-------------- Restart --------------\n---------------- Nah ----------------' | fuzzel --dmenu --prompt="Shutdown? ")"

if [ "$respond" = '---------------- Yes ----------------' ] 
then
    echo "shutdown"
	shutdown now    
elif [ "$respond" = '-------------- Restart --------------' ] 
then
    echo "restart"
    reboot
else
    notify-send "cancel shutdown"
fi
