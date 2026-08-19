# __herdr_launch_agent — shared engine for the pi/claude herdr wrappers.
#
# One workspace per cwd, shared by every agent kind (pi and claude in the
# same folder land in the same workspace, different tabs). Reuses a live
# agent of the requested kind when its session is still fresh (no
# conversation yet), otherwise starts a new numbered tab:
#   pi, pi-2, pi-3 ... / claude, claude-2, claude-3 ...
#
# Usage: __herdr_launch_agent <kind> [args...]   (kind is also the base name)
#
# Extra args are passed through to the agent process (`pi --resume`, `claude
# -c`, a direct prompt, ...). When args are present the fresh-tab reuse is
# skipped — reusing would silently drop them, and flags like --resume only
# make sense on a freshly started agent.

function __herdr_launch_agent -a kind
    # 1. Make sure the herdr server is up — the CLI talks over its socket.
    if not herdr status server 2>/dev/null | string match -q 'status: running'
        nohup herdr server >/dev/null 2>&1 &
        for i in (seq 1 50)
            herdr status server 2>/dev/null | string match -q 'status: running'; and break
            sleep 0.2
        end
        if not herdr status server 2>/dev/null | string match -q 'status: running'
            echo "herdr: server did not start — falling back to plain $kind" >&2
            command $kind $argv[2..-1]
            return 1
        end
    end

    set -l cwd (pwd -P)
    set -l agents (herdr agent list 2>/dev/null)

    # 2. Resolve the shared workspace for this cwd. Agents know their cwd,
    #    then panes, then git worktrees — in that order.
    set -l wid (echo "$agents" | jq -r --arg cwd "$cwd" '.result.agents[] | select((.cwd // "") == $cwd or (.foreground_cwd // "") == $cwd) | .workspace_id' 2>/dev/null | head -1)
    if test -z "$wid"
        set wid (herdr pane list 2>/dev/null | jq -r --arg cwd "$cwd" '.result.panes[] | select((.cwd // "") == $cwd) | .workspace_id' 2>/dev/null | head -1)
    end
    if test -z "$wid"
        set wid (herdr workspace list 2>/dev/null | jq -r --arg cwd "$cwd" '.result.workspaces[] | select((.worktree.checkout_path // "") == $cwd) | .workspace_id' 2>/dev/null | head -1)
    end

    # 3. Decide the agent name: reuse the lowest-numbered live agent of this
    #    kind in the workspace when its session is still fresh, otherwise the
    #    next free number (plain name first, then -2, -3, ...).
    set -l agent_name ""
    set -l reuse_tab ""
    set -l pane ""

    if test -z "$wid"
        # No workspace yet — create one; its root pane is the agent's home.
        set -l ws_json (herdr workspace create --cwd "$cwd" --label (basename "$cwd") --focus 2>/dev/null)
        set wid (echo "$ws_json" | jq -r '.result.workspace_id // empty' 2>/dev/null)
        set pane (echo "$ws_json" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
        set agent_name $kind
    else
        set -l rows (echo "$agents" | jq -r --arg ws "$wid" --arg base "$kind" \
            '.result.agents[] | select(.workspace_id == $ws and (.name == $base or (.name | test("^" + $base + "-[0-9]+$")))) | [.name, (.agent_session.value // ""), .tab_id] | @tsv' 2>/dev/null)
        set -l max_n 1
        for row in $rows
            set -l parts (string split \t -- $row)
            set -l aname $parts[1]
            set -l sess $parts[2]
            set -l tab $parts[3]
            set -l n 1
            if test "$aname" != "$kind"
                set n (string replace -r "^$kind-([0-9]+)\$" '$1' -- "$aname")
            end
            if test "$n" -gt "$max_n"
                set max_n $n
            end
            # Only reuse a fresh tab when there is nothing to pass through —
            # args (`--resume`, a prompt, ...) need a fresh agent process.
            if test -z "$agent_name"; and test (count $argv) -le 1; and __herdr_agent_is_fresh "$kind" "$sess" "$cwd"
                set agent_name $aname
                set reuse_tab $tab
            end
        end
        if test (count $rows) -eq 0
            set agent_name $kind
        else if test -z "$agent_name"
            set agent_name "$kind-"(math $max_n + 1)
        end
    end

    # 4. Agent names are globally unique among live agents — bump ours if a
    #    same-named agent lives in another workspace (rare).
    while echo "$agents" | jq -e --arg n "$agent_name" --arg ws "$wid" '.result.agents[] | select(.name == $n and .workspace_id != $ws)' >/dev/null 2>&1
        if test "$agent_name" = "$kind"
            set agent_name "$kind-2"
        else
            set agent_name "$kind-"(math (string replace -r "^$kind-([0-9]+)\$" '$1' -- "$agent_name") + 1)
        end
    end

    # 5. Fresh session → just attach to the existing tab.
    if test -n "$reuse_tab"
        herdr workspace focus "$wid" >/dev/null 2>&1
        herdr tab focus "$reuse_tab" >/dev/null 2>&1
        herdr
        return 0
    end

    # 6. New tab (existing workspace) or root pane (fresh workspace).
    if test -z "$pane"
        set pane (herdr tab create --workspace "$wid" --cwd "$cwd" --label "$agent_name" --focus 2>/dev/null | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
    end

    if test -n "$pane"
        # Pass the caller's args through to the agent after `--` (pi --resume,
        # claude -c, direct prompts, ...). This path is only reached with args
        # when no tab was reused, so the agent process starts fresh with them.
        set -l cmd herdr agent start "$agent_name" --kind "$kind" --pane "$pane" --timeout 45000
        if test (count $argv) -gt 1
            set -a cmd --
            set -a cmd $argv[2..-1]
        end
        if not $cmd >/dev/null 2>&1
            echo "herdr: agent start failed — attached to a shell pane, start $kind manually" >&2
        end
    else
        echo "herdr: could not create a workspace/pane — falling back to plain $kind" >&2
        command $kind $argv[2..-1]
        return 1
    end

    # 7. Attach the TUI. Detach with ctrl+b q — the agent keeps running.
    herdr
end

# __herdr_agent_is_fresh <kind> <session_path> <cwd>
#
# A session is fresh when its transcript is missing or still tiny. pi reports
# the exact session file via the herdr extension (agent_session.value);
# claude only reports it after SessionStart fires, so fall back to the newest
# transcript in the project dir — fresh if it is missing, old, or tiny.
function __herdr_agent_is_fresh -a kind sess cwd
    set -l f ""
    if test -n "$sess"
        set f "$sess"
    else if test "$kind" = claude
        set -l enc (string replace -a -r '[^a-zA-Z0-9]' '-' -- "$cwd")
        set f (ls -t "$HOME/.claude/projects/$enc/"*.jsonl 2>/dev/null | head -1)
    end
    if test -z "$f"; or not test -f "$f"
        return 0
    end

    set -l size (wc -c < "$f" 2>/dev/null | string trim)
    if test -z "$size"
        return 1 # unreadable — treat as in-use rather than dump into it
    end

    if test "$kind" = claude; and test -z "$sess"
        # No exact path: a big transcript from an earlier session must not
        # count — only a fresh transcript (recent + sizable) means the agent
        # is mid-conversation.
        set -l mtime (stat -c %Y "$f" 2>/dev/null)
        if test -z "$mtime"
            return 0
        end
        set -l age (math (date +%s) - $mtime)
        if test $age -gt 600 # 10 minutes of quiet = fresh
            return 0
        end
        if test "$size" -le 4096
            return 0
        end
        return 1
    end

    test "$size" -le 2048; and return 0; or return 1
end
