# pi — always launch the pi agent inside herdr
#
#   pi    → herdr-managed tab in the shared workspace for the current
#           directory. Reuses the running pi tab when its session is still
#           fresh (no conversation yet), otherwise opens a new numbered tab
#           (pi, pi-2, pi-3, ...). Attaches the herdr TUI (detach with
#           ctrl+b q; pi keeps running).
#   pib   → plain pi, bypasses herdr entirely (escape hatch).
#
# Running inside a herdr pane already (HERDR_ENV=1) just runs pi here — the
# pane is already herdr-managed, no need to nest.

function pi -d "Launch pi inside herdr (shared workspace, numbered tabs). pib = plain pi"
    # Already in a herdr-managed pane → that pane IS herdr; run pi here.
    if set -q HERDR_ENV
        command pi $argv
        return
    end
    __herdr_launch_agent pi $argv
end
