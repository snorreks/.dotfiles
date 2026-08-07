function nvmode --description 'Switch NVIDIA graphics modes or query the current mode'
    set -l mode $argv[1]

    if test (count $argv) -eq 0
        envycontrol -q
    else
        switch $mode
            case integrated hybrid nvidia
                sudo envycontrol -s $mode
            case '*'
                echo "Invalid mode: $mode"
                echo "Valid modes are: integrated, hybrid, nvidia"
                return 1
        end
    end
end
