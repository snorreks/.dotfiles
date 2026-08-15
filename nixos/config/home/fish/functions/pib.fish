# pib — plain pi, bypasses the herdr wrapper (escape hatch).
#
#   pi  → pi inside herdr (managed pane + TUI)
#   pib → plain pi, exactly like typing the pi binary directly

function pib -d "Plain pi — bypass the herdr wrapper (escape hatch)"
    command pi $argv
end
