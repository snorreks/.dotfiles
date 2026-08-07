function global_control
    set EnableWallDcol 0
    set ConfDir "$XDG_CONFIG_HOME"
    if test -z "$ConfDir"
        set ConfDir "$HOME/.config"
    end
    set cacheDir "$HOME/.cache/mangodots"

    set gtkTheme 'Decay-Green'
    set gtkMode 'dark'

    set wm_border 0
    set wm_width 0

    function pkg_installed
        set PkgIn $argv[1]
        if pacman -Qi $PkgIn > /dev/null 2>&1
            return 0
        else
            return 1
        end
    end

    function get_aurhlpr
        if pkg_installed yay
            set aurhlpr "yay"
        else if pkg_installed paru
            set aurhlpr "paru"
        end
    end

    function check
        set Pkg_Dep
        for PkgIn in $argv
            if not pkg_installed $PkgIn
                set Pkg_Dep $Pkg_Dep $PkgIn
            end
        end
        if test -n "$Pkg_Dep"
            echo "$0 Dependencies:\n$Pkg_Dep"
            read -p "ENTER to install  (Other key: Cancel): " ans
            if test -z "$ans"
                get_aurhlpr
                eval $aurhlpr -S $Pkg_Dep
            else
                echo "Skipping installation of packages"
                return 1
            end
        end
    end
end
