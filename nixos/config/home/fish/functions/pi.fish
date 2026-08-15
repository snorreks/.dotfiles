# pi — always launch the pi agent inside herdr
#
#   pi  → herdr-managed pane in a workspace for the current directory, then
#         attach the herdr TUI (detach with ctrl+b q; pi keeps running).
#         Reuses an existing pi agent / workspace for this cwd instead of
#         double-spawning.
#   pib → plain pi, bypasses herdr entirely (escape hatch).
#
# Running inside a herdr pane already (HERDR_ENV=1) just runs pi here — the
# pane is already herdr-managed, no need to nest.

function pi -d "Launch pi inside herdr (workspace per cwd, agent pane, attach TUI). pib = plain pi"
    # Already in a herdr-managed pane → that pane IS herdr; run pi here.
    if set -q HERDR_ENV
        command pi $argv
        return
    end

    # 1. Make sure the herdr server is up — the CLI talks over its socket.
    if not herdr status server 2>/dev/null | string match -q 'status: running'
        nohup herdr server >/dev/null 2>&1 &
        for i in (seq 1 50)
            herdr status server 2>/dev/null | string match -q 'status: running'; and break
            sleep 0.2
        end
        if not herdr status server 2>/dev/null | string match -q 'status: running'
            echo "herdr: server did not start — falling back to plain pi (pib)" >&2
            command pi $argv
            return 1
        end
    end

    set -l cwd (pwd -P)

    # 2. Reuse: a pi agent is already running in this directory.
    set -l live (herdr agent list 2>/dev/null | jq -r --arg cwd "$cwd" '.result.agents[] | select((.cwd // "") == $cwd or (.foreground_cwd // "") == $cwd) | .name' | head -1)
    if test -n "$live"
        set -l wsid (herdr agent list 2>/dev/null | jq -r --arg cwd "$cwd" '.result.agents[] | select((.cwd // "") == $cwd or (.foreground_cwd // "") == $cwd) | .workspace_id' | head -1)
        test -n "$wsid"; and herdr workspace focus "$wsid" >/dev/null 2>&1
        herdr
        return
    end

    # 3. Reuse the workspace herdr already made for this directory (git repos
    #    carry their checkout path; non-repo dirs always create fresh).
    set -l wid (herdr workspace list 2>/dev/null | jq -r --arg cwd "$cwd" '.result.workspaces[] | select((.worktree.checkout_path // "") == $cwd) | .workspace_id' | head -1)

    # 4. Get a fresh shell pane and start pi in it.
    set -l pane
    if test -n "$wid"
        set pane (herdr tab create --workspace "$wid" --cwd "$cwd" --label pi --focus 2>/dev/null | jq -r '.result.root_pane.pane_id // empty')
    else
        set -l ws_json (herdr workspace create --cwd "$cwd" --label (basename "$cwd") --focus 2>/dev/null)
        set pane (echo "$ws_json" | jq -r '.result.root_pane.pane_id // empty')
    end

    if test -n "$pane"
        if not herdr agent start pi --kind pi --pane "$pane" --timeout 45000 >/dev/null 2>&1
            echo "herdr: agent start failed — attached to a shell pane, start pi manually" >&2
        end
    else
        echo "herdr: could not create a workspace/pane — falling back to plain pi (pib)" >&2
        command pi $argv
        return 1
    end

    # 5. Attach the TUI. Detach with ctrl+b q — the pi agent keeps running.
    herdr
end
