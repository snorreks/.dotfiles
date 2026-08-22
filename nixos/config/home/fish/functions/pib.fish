# pib — plain pi, bypasses the herdr wrapper (escape hatch).
#
#   pi  → pi inside herdr (managed pane + TUI)
#   pib → plain pi, exactly like typing the pi binary directly

function pib -d "Plain pi — bypass the herdr wrapper (escape hatch)"
    command pi $argv
end

# pilb — plain pi-local, bypasses the herdr wrapper (escape hatch).
# Same model/flags semantics as `pil` (see pi.fish), but runs the pi binary
# directly instead of inside a herdr-managed pane.

function pilb -d "Plain pi-local — bypass the herdr wrapper (escape hatch)"
    set -l model gemma4-pi
    if set -q argv[1]
        set model $argv[1]
        set -e argv[1]
    end
    set -l flags (__pi_local_flags $model)
    command pi --provider ollama --model "$model" $flags $argv
end
