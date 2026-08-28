# claudeb — plain claude, bypasses the herdr wrapper (escape hatch).
#
#   claude   → claude inside herdr (managed pane + TUI)
#   claudeb  → plain claude, exactly like typing the claude binary directly

function claudeb -d "Plain claude — bypass the herdr wrapper (escape hatch)"
    command claude $argv
end
