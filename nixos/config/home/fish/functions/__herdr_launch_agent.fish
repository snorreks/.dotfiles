# __herdr_launch_agent — shared engine for the pi/claude herdr wrappers.
#
# One workspace per cwd, shared by every agent kind (pi and claude in the
# same folder land in the same workspace, different tabs). Reuses a live
# agent of the requested kind when its session is still fresh (no
# conversation yet), otherwise starts a tab on the lowest free number:
#   pi, pi-2, pi-3 ... / claude, claude-2, claude-3 ...
#
# Only workspaces this wrapper owns are ever joined — see step 2. Machine-owned
# workspaces (aikami-contract-*, aikami-task-*, aikami-{mode}) are off limits:
# their lifecycle belongs to the contract pipeline and `herdr:stop-all`, both of
# which close the whole workspace and would take the agent tab with it.
#
# Usage: __herdr_launch_agent <kind> [args...]   (kind is also the base name)
#
# Extra args are passed through to the agent process (`pi --resume`, `claude
# -c`, a direct prompt, ...). When args are present the fresh-tab reuse is
# skipped — reusing would silently drop them, and flags like --resume only
# make sense on a freshly started agent.

function __herdr_launch_agent -a kind
    # 1. Make sure the herdr server is up — the CLI talks over its socket.
    #
    # Never start it as a shell job. A backgrounded `herdr server` stays in
    # THIS foot window's session with its pty as controlling terminal, and
    # herdr's signal handler treats SIGHUP as "quit" (it links ctrlc with the
    # `termination` feature, which overrides nohup's SIG_IGN). Closing that one
    # window then took the server down and every agent pane and contract
    # pipeline run with it. See config/home/herdr.nix for the full write-up.
    if not herdr status server 2>/dev/null | string match -q 'status: running'
        # Supervised unit first — it owns the server's lifecycle.
        if not systemctl --user start herdr.service 2>/dev/null
            # No user unit (non-NixOS shell, masked service, ...). setsid -f
            # forks and puts the server in its own session with no controlling
            # terminal, which is what herdr's own daemon spawn does.
            setsid -f herdr server >/dev/null 2>&1
        end
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
    set -l base (basename "$cwd")
    set -l agents (herdr agent list 2>/dev/null | string collect)

    # 2. Resolve the workspace for this cwd.
    #
    # Identity is the LABEL plus a pane actually sitting in this cwd. It used
    # to be "some agent has this cwd", then "some pane has this cwd", and that
    # is how `pi` in the repo root ended up inside a running contract
    # pipeline: a contract workspace legitimately holds panes at the repo root
    # (the pipeline and review/captain tabs run from the main checkout, not
    # the worktree — see ContractHerdrAdapter._createWorkerTab), so the pane
    # scan matched aikami-contract-C-NNN and `head -1` took it. Joining it is
    # not a cosmetic mistake: `workspace:cleanup` closes that workspace whole
    # when the contract retires, taking the agent tab with it. The label is
    # what separates them — this wrapper labels its workspaces basename(cwd),
    # and every machine-owned workspace carries a prefix instead
    # (aikami-contract-*, aikami-task-*, aikami-{mode}).
    #
    # 🔴 Do NOT switch this back to `.worktree.checkout_path` alone. That field
    # is `Option<WorkspaceWorktreeInfo>`, populated from `ws.worktree_space()`
    # — only workspaces in one of herdr's worktree GROUPS have it, which a
    # plain `workspace create --cwd` is not. Keying on it made every lookup
    # miss and every `pi` create yet another duplicate `aikami` workspace.
    #
    #   rank 0  label == basename(cwd), and a pane of that workspace is here.
    #   rank 1  a linked git worktree rooted exactly here — one checkout, one
    #           owner, whatever it is labelled. Creating a rival workspace on
    #           the same checkout is worse than joining: its panes hold the
    #           cwd and make `git worktree remove` fail.
    #   rank 2  label == basename(cwd) but every pane has since cd'd away.
    #           Weak, but never worse than making a second workspace with a
    #           label we already own.
    set -l panes_json (herdr pane list 2>/dev/null | string collect)
    test -n "$panes_json"; or set panes_json '{}'
    set -l wid (herdr workspace list 2>/dev/null | jq -r \
        --arg cwd "$cwd" --arg base "$base" --argjson panes "$panes_json" '
        ([($panes.result.panes // [])[] | select((.cwd // "") == $cwd) | .workspace_id]) as $here
        | [ .result.workspaces[]
            | { id: .workspace_id,
                rank: (if (.label == $base and (.workspace_id | IN($here[]))) then 0
                       elif ((.worktree.checkout_path // "") == $cwd
                             and (.worktree.is_linked_worktree // false)) then 1
                       elif .label == $base then 2
                       else 3 end) }
            | select(.rank < 3)
          ] | sort_by(.rank) | .[0].id // empty' 2>/dev/null)

    # 3. Decide the agent name: reuse the lowest-numbered live agent of this
    #    kind in the workspace when its session is still fresh, otherwise the
    #    lowest free number (plain name first, then -2, -3, ...).
    set -l agent_name ""
    set -l reuse_tab ""
    set -l pane ""

    if test -z "$wid"
        # No workspace yet — create one; its root pane is the agent's home.
        # The id is under .result.workspace.workspace_id — the response is
        # WorkspaceCreated { workspace, tab, root_pane }, not a bare id. Reading
        # .result.workspace_id yielded empty forever; it went unnoticed only
        # because root_pane was still correct and $wid happened to be unused on
        # this path.
        set -l ws_json (herdr workspace create --cwd "$cwd" --label "$base" --focus 2>/dev/null | string collect)
        set wid (echo $ws_json | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
        set pane (echo $ws_json | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
        if test -z "$wid"; or test -z "$pane"
            echo "herdr: could not create a workspace for $cwd — falling back to plain $kind" >&2
            command $kind $argv[2..-1]
            return 1
        end
    end

    # Numbers already used by live agents of this kind ANYWHERE. herdr requires
    # agent names to be globally unique, so the free number has to be free
    # across every workspace — checking only this one, then bumping against the
    # others afterwards, could land back on a number taken here.
    # `select(type == "string")` is load-bearing: an agent herdr detected but
    # never named (started by hand in a pane, not through this wrapper) has
    # name: null, and `null | test(...)` is a hard jq error that aborts the
    # whole stream — silently dropping every agent after it and handing back a
    # number that is already taken.
    set -l taken (echo $agents | jq -r --arg base "$kind" '
        .result.agents[].name
        | select(type == "string")
        | select(. == $base or test("^" + $base + "-[0-9]+$"))
        | if . == $base then 1 else (ltrimstr($base + "-") | tonumber) end' 2>/dev/null)

    # A freshly created workspace ($pane already set) has nothing to reuse, and
    # falls straight through to the naming block below — it must NOT shortcut to
    # the plain `$kind` name, which is very often already taken by the agent in
    # another project's workspace.
    if test -z "$pane"
        set -l rows (echo $agents | jq -r --arg ws "$wid" --arg base "$kind" \
            '.result.agents[]
             | select(.workspace_id == $ws)
             | (.name // "") as $n
             | select($n == $base or ($n | test("^" + $base + "-[0-9]+$")))
             | [$n, (.agent_session.value // ""), .tab_id] | @tsv' 2>/dev/null)

        # Lowest-numbered fresh agent wins — jq returns agents in herdr's own
        # order, which is not numeric, so compare rather than take the first.
        set -l fresh_n ""
        for row in $rows
            set -l parts (string split \t -- $row)
            set -l aname $parts[1]
            set -l sess $parts[2]
            set -l tab $parts[3]
            set -l n 1
            if test "$aname" != "$kind"
                set n (string replace -r "^$kind-([0-9]+)\$" '$1' -- "$aname")
            end
            # Only reuse a fresh tab when there is nothing to pass through —
            # args (`--resume`, a prompt, ...) need a fresh agent process.
            if test (count $argv) -le 1; and __herdr_agent_is_fresh "$kind" "$sess" "$cwd"
                if test -z "$fresh_n"; or test "$n" -lt "$fresh_n"
                    set fresh_n $n
                    set agent_name $aname
                    set reuse_tab $tab
                end
            end
        end
    end

    if test -z "$agent_name"
        set -l n 1
        while contains -- $n $taken
            set n (math $n + 1)
        end
        if test $n -eq 1
            set agent_name $kind
        else
            set agent_name "$kind-$n"
        end
    end

    # 4. Fresh session → just attach to the existing tab.
    if test -n "$reuse_tab"
        herdr workspace focus "$wid" >/dev/null 2>&1
        herdr tab focus "$reuse_tab" >/dev/null 2>&1
        herdr
        return 0
    end

    # 5. New tab (existing workspace) or root pane (fresh workspace).
    if test -z "$pane"
        set pane (herdr tab create --workspace "$wid" --cwd "$cwd" --label "$agent_name" --focus 2>/dev/null | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
    end

    if test -z "$pane"
        echo "herdr: could not create a pane in $wid — falling back to plain $kind" >&2
        command $kind $argv[2..-1]
        return 1
    end

    # Pass the caller's args through to the agent after `--` (pi --resume,
    # claude -c, direct prompts, ...). This path is only reached with args
    # when no tab was reused, so the agent process starts fresh with them.
    set -l cmd herdr agent start "$agent_name" --kind "$kind" --pane "$pane" --timeout 45000
    if test (count $argv) -gt 1
        set -a cmd --
        set -a cmd $argv[2..-1]
    end
    # Keep stderr: "agent start failed" on its own says nothing about whether
    # the name collided, the pane died or the 45s timeout was hit, and the
    # pane you are dropped into looks identical in all three cases.
    # No `| string collect` here: a pipeline's $status is the LAST stage's, and
    # `string collect` exits 1 on empty input — which inverts the check exactly
    # when the agent started fine and printed nothing.
    set -l err ($cmd 2>&1 >/dev/null)
    if test $status -ne 0
        echo "herdr: agent start failed — attached to a shell pane, start $kind manually" >&2
        if test (count $err) -gt 0
            echo "herdr:" (string join " " -- $err) >&2
        end
    end

    # 6. Attach the TUI. Detach with ctrl+b q — the agent keeps running.
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
