# __pi_local_flags — compute the pi-local launch flags for a given ollama model.
#
# Mirrors ~/.pi/local-models/pi-local: drops skills (-ns) unless PI_LOCAL_SKILLS=1,
# drops extensions (-ne) for qwen* models (their 32K window can't fit the full
# aikami prompt) unless PI_LOCAL_EXTENSIONS=1, and appends the nudge system
# prompt unless PI_LOCAL_NUDGE=0.
#
# Usage: set -l flags (__pi_local_flags <model>)

function __pi_local_flags -a model
    set -l flags

    # Skills off by default — ~11K tokens of skill descriptions.
    if not set -q PI_LOCAL_SKILLS; or test "$PI_LOCAL_SKILLS" != 1
        set -a flags -ns
    end

    switch $model
        case 'qwen*'
            # qwen3.8-xs-pi declares 32K; skills+extensions (~25K) leave no
            # room for output → "Response was truncated before completion".
            if not set -q PI_LOCAL_EXTENSIONS; or test "$PI_LOCAL_EXTENSIONS" != 1
                set -a flags -ne
            end
        case '*'
            # 64K models (gemma4-pi, ornith-pi) can afford extensions unless
            # explicitly disabled.
            if set -q PI_LOCAL_EXTENSIONS; and test "$PI_LOCAL_EXTENSIONS" = 0
                set -a flags -ne
            end
    end

    set -l nudge "$HOME/.pi/local-models/nudge.md"
    if not set -q PI_LOCAL_NUDGE; or test "$PI_LOCAL_NUDGE" = 1
        if test -f "$nudge"
            set -a flags --append-system-prompt "$nudge"
        end
    end

    printf '%s\n' $flags
end
