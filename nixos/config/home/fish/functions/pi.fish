# pi — always launch the pi agent inside herdr
#
#   pi    → herdr-managed tab in the shared workspace for the current
#           directory. Reuses the running pi tab when its session is still
#           fresh (no conversation yet), otherwise opens a new numbered tab
#           (pi, pi-2, pi-3, ...). Attaches the herdr TUI (detach with
#           ctrl+b q; pi keeps running).
#
#   Any extra args are passed through to pi (`pi --resume`, `pi "prompt"`,
#   ...). With args a fresh tab is always started — reuse would drop them.
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

# pil — pi against a local ollama model, inside herdr (pi-local).
#
#   pil            → gemma4-pi, skills off
#   pil ornith     → ornith-pi, skills off
#   pil qwen       → qwen3.8-xs-pi, skills AND extensions off (32K window)
#   pil gemma4-pi -- -p "prompt"   → everything after -- goes to pi
#
#   PI_LOCAL_SKILLS=1      → keep skills (~11K extra tokens)
#   PI_LOCAL_EXTENSIONS=0  → also drop extension/package tools (~12K)
#   PI_LOCAL_NUDGE=0       → skip the nudge system prompt
#
# Why: in a project like aikami, pi's first request already carries ~25K tokens
# before you type anything. A local model with a 24-64K window has nothing left
# and every reply comes back "truncated before completion". This trims the
# prompt so the model has working room. pilb = plain pi-local (no herdr).

function pil -d "Launch pi against a local ollama model inside herdr (pi-local). pilb = plain"
    set -l model gemma4-pi
    if set -q argv[1]
        set model $argv[1]
        set -e argv[1]
    end
    set -l flags (__pi_local_flags $model)

    # Already in a herdr-managed pane → that pane IS herdr; run pi here.
    if set -q HERDR_ENV
        command pi --provider ollama --model "$model" $flags $argv
        return
    end
    __herdr_launch_agent pi --provider ollama --model "$model" $flags $argv
end
