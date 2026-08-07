function zed-fix
    set display echo $WAYLAND_DISPLAY
    WAYLAND_DISPLAY $display zeditor $argv
end
