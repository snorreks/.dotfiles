# claude — always launch the claude agent inside herdr
#
#   claude   → herdr-managed tab in the shared workspace for the current
#              directory. Reuses the running claude tab when its session is
#              still fresh (no conversation yet), otherwise opens a new
#              numbered tab (claude, claude-2, claude-3, ...). Attaches the
#              herdr TUI (detach with ctrl+b q; claude keeps running).
#
#   Any extra args are passed through to claude (`claude --resume <id>`, a
#   direct prompt, ...). With args a fresh tab is always started — reuse
#   would drop them.
#   claudeb  → plain claude, bypasses herdr entirely (escape hatch).
#
# Running inside a herdr pane already (HERDR_ENV=1) just runs claude here —
# the pane is already herdr-managed, no need to nest.

function claude -d "Launch claude inside herdr (shared workspace, numbered tabs). claudeb = plain claude"
    # Already in a herdr-managed pane → that pane IS herdr; run claude here.
    if set -q HERDR_ENV
        command claude $argv
        return
    end
    __herdr_launch_agent claude $argv
end
