# update_dotfiles — scoped, reviewable changes to the dotfiles repo.
#
# REPLACES a version of this function that did three unsafe things:
#
#   1. `sudo chown -R sonny:users ~/.dotfiles` on every invocation, which
#      walked the entire repository — including `.git` — and rewrote ownership
#      of files it did not own or need to touch.
#   2. `git add -A`, which stages whatever happens to be in the tree. If a
#      private key, a build artifact, or a local override had been dropped in
#      the directory, it went into the commit, and the next step pushed it.
#   3. `git push origin master` unconditionally, so every change landed
#      straight on master with no review, no branch, and no way back.
#
# The three together mean "run this to fix permissions" could publish a secret
# to a public repository. The workflow below keeps the useful capabilities
# (fix ownership, commit, push) and removes the part where they fire on their
# own.
#
# Usage:
#   update_dotfiles status              what has changed, and where we are
#   update_dotfiles stage <path>...      stage ONLY the paths named
#   update_dotfiles unstage <path>...    unstage paths
#   update_dotfiles review               read the staged diff before committing
#   update_dotfiles commit <message>     commit what is staged
#   update_dotfiles branch <name>        create/switch to a topic branch
#   update_dotfiles push                 push the CURRENT branch (never master)
#   update_dotfiles pr <title>           push + open a DRAFT pull request
#   update_dotfiles sync                 fetch and report divergence
#   update_dotfiles fixperms <path>...   chown ONLY the paths named (sudo)
#
# Notes:
#   * Every mutating subcommand takes explicit paths. There is no "stage all",
#     by design. `status` lists untracked files precisely so you can name them.
#   * Nothing here pushes to master. `commit` on master is refused outright.
#   * `fixperms` refuses a path that resolves to the repository root, so
#     "fix permissions" cannot become a recursive rewrite again.

function update_dotfiles --description "Scoped, reviewable dotfiles changes (no blanket chown, add-all, or master push)"
    # Defaults to the live checkout. NM_DOTFILES_REPO overrides it, which is
    # what lets this be driven against a throwaway repository in tests and
    # what makes the function usable from a linked worktree.
    set -l REPO "$HOME/.dotfiles"
    if set -q NM_DOTFILES_REPO
        set REPO "$NM_DOTFILES_REPO"
    end

    if not test -d "$REPO/.git"
        echo "update_dotfiles: $REPO is not a git repository" >&2
        return 1
    end

    # Refuse to commit on master. A commit is not itself dangerous, but every
    # path from here leads to a push, and the point of a branch is that the
    # push goes somewhere reviewable.
    #
    # `$repo` is passed in rather than read from the enclosing scope: a `set -l`
    # local of update_dotfiles is not visible inside a nested function here, and
    # an empty `$repo` silently becomes `git -C branch ...` rather than a
    # visible error.
    function _ud_guard_not_master
        set -l repo $argv[1]
        set -l branch (command git -C "$repo" branch --show-current)
        if test "$branch" = "master"
            echo "update_dotfiles: refusing to work directly on master." >&2
            echo "  Create a topic branch first:  update_dotfiles branch <name>" >&2
            return 1
        end
        return 0
    end

    # Guard `stage` against paths that must never enter a commit. The
    # repository .gitignore already keeps these out of `git add .`; naming them
    # here means an explicit `stage <path>` is refused too, because a function
    # that only warns is a function people override.
    #
    # `$repo` is passed in for the same reason as `_ud_guard_not_master`: a
    # `set -l` local of update_dotfiles is not visible inside a nested function
    # here, so referencing `$REPO` in the message produced an empty path.
    function _ud_guard_staging_paths
        set -l repo $argv[1]
        set -l files $argv[2..-1]

        set -l forbidden '*.age' '*.key' 'id_rsa*' 'keys.txt' \
            'nixos/secrets.nix' 'nixos/local.nix' \
            'nixos/config/home/files/.ssh/*' 'nixos/config/home/files/.aws/*' \
            'nixos/config/home/vpn/configs/*' '*__pycache__*' '*/target/*' 'result*'

        # The root is resolved once, the same way `fixperms` resolves it, so
        # the two agree on what "the repository" is even when NM_DOTFILES_REPO
        # is a symlink.
        set -l root (realpath -m -- $repo)

        for path in $files
            # Resolve first, match second. The previous version matched the
            # literal string the caller typed, so `./keys.txt`,
            # `nixos/./secrets.nix` and `nixos//secrets.nix` all walked past
            # every glob in the list. `realpath -m` collapses `.` segments,
            # duplicate slashes and trailing slashes without requiring the file
            # to exist.
            set -l target $path
            if not string match -q '/*' -- $path
                set target "$root/$path"
            end
            set -l abs (realpath -m -- $target 2>/dev/null)

            if test -z "$abs" || test "$abs" = "$root"
                echo "update_dotfiles: refusing to stage '$path' — it is the repository root." >&2
                echo "  Name the specific files instead." >&2
                return 1
            end

            set -l rel (string replace -- "$root/" '' $abs)
            if test -z "$rel" || test "$rel" = "$abs"
                echo "update_dotfiles: refusing to stage '$path' — it is the repository root." >&2
                return 1
            end

            # A directory is never something to stage, and `stage .` is
            # `git add -A` with extra steps — the exact behaviour this
            # function exists to remove.
            if test -d "$abs"
                echo "update_dotfiles: refusing to stage '$path' — it is a directory." >&2
                echo "  Name the specific files inside it instead." >&2
                return 1
            end

            for pattern in $forbidden
                if string match -q -- "$pattern" $rel
                    echo "update_dotfiles: refusing to stage '$path' (matches '$pattern')." >&2
                    echo "  If this really belongs in the repository, add it deliberately" >&2
                    echo "  with git -C $repo add -f -- $rel" >&2
                    return 1
                end
            end
        end
        return 0
    end

    set -l cmd status
    if test (count $argv) -gt 0
        set cmd $argv[1]
        set -e argv[1]
    end

    switch $cmd
        case status
            echo "── branch ─────────────────────────────────────────"
            command git -C $REPO status -sb --untracked-files=normal

            echo
            echo "── staged (will be committed) ──────────────────────"
            if command git -C $REPO diff --cached --quiet
                echo "  (nothing staged)"
            else
                command git -C $REPO diff --cached --stat
            end

            echo
            echo "── unstaged changes ────────────────────────────────"
            command git -C $REPO diff --stat

            echo
            echo "── untracked (NOT staged; name them explicitly) ────"
            set -l untracked (command git -C $REPO ls-files --others --exclude-standard)
            if test (count $untracked) -eq 0
                echo "  (none)"
            else
                for f in $untracked
                    echo "  $f"
                end
                echo
                echo "  stage with:  update_dotfiles stage <path>"
            end

        case stage
            if test (count $argv) -eq 0
                echo "update_dotfiles: stage needs at least one path." >&2
                echo "  There is no 'stage everything': status lists untracked files." >&2
                return 1
            end
            _ud_guard_staging_paths "$REPO" $argv; or return 1
            # `--` before the paths so a filename cannot be read as an option.
            command git -C $REPO add -- $argv
            echo "staged: $argv"
            echo "review with:  update_dotfiles review"

        case unstage
            if test (count $argv) -eq 0
                echo "update_dotfiles: unstage needs at least one path." >&2
                return 1
            end
            command git -C $REPO restore --staged -- $argv

        case review
            if command git -C $REPO diff --cached --quiet
                echo "update_dotfiles: nothing staged to review." >&2
                return 1
            end
            # The whole point of the subcommand: read it before committing it.
            command git -C $REPO diff --cached

        case commit
            if test (count $argv) -eq 0
                echo "update_dotfiles: commit needs a message." >&2
                return 1
            end
            _ud_guard_not_master "$REPO"; or return 1
            if command git -C $REPO diff --cached --quiet
                echo "update_dotfiles: nothing staged; nothing to commit." >&2
                echo "  stage explicitly:  update_dotfiles stage <path>" >&2
                return 1
            end
            command git -C $REPO commit -m "$argv"

        case branch
            if test (count $argv) -eq 0
                echo "update_dotfiles: branch needs a name." >&2
                return 1
            end
            command git -C $REPO switch -c "$argv"
            echo "on branch: $argv"

        case push
            _ud_guard_not_master "$REPO"; or return 1
            set -l branch (command git -C $REPO branch --show-current)
            # --set-upstream, and the branch named explicitly: never rely on the
            # remote's current HEAD.
            command git -C $REPO push --set-upstream origin "$branch"

        case pr
            if test (count $argv) -eq 0
                echo "update_dotfiles: pr needs a title." >&2
                return 1
            end
            _ud_guard_not_master "$REPO"; or return 1
            set -l branch (command git -C $REPO branch --show-current)
            command git -C $REPO push --set-upstream origin "$branch"; or return 1
            # Draft, always. A pull request opened from this function has been
            # written by an agent or a hurried edit and has not been read by a
            # person yet; making it draft is the honest default. Promote it
            # manually once reviewed.
            command gh pr create --draft --repo snorreks/.dotfiles \
                --base master --head "$branch" --title "$argv"

        case sync
            command git -C $REPO fetch --all --prune
            echo
            command git -C $REPO status -sb
            echo
            echo "This function does not merge, rebase, or reset."
            echo "Review the divergence and do that deliberately."

        case fixperms
            if test (count $argv) -eq 0
                echo "update_dotfiles: fixperms needs at least one explicit path." >&2
                echo "  e.g. update_dotfiles fixperms nixos/config/home/scripts/scripts/foo.sh" >&2
                return 1
            end
            # Resolve the repository root ONCE, then resolve every requested
            # path against it. The guard and the chown must act on the same
            # absolute targets: guarding `./x` and then chowning `$argv` means
            # guarding one string and operating on another.
            set -l root (realpath -m -- $REPO)
            set -l targets
            for path in $argv
                set -l target $path
                if not string match -q '/*' -- $path
                    set target "$root/$path"
                end
                set -l abs (realpath -m -- $target 2>/dev/null)
                if test -z "$abs"
                    echo "update_dotfiles: cannot resolve '$path'." >&2
                    return 1
                end
                if test "$abs" = "$root"
                    echo "update_dotfiles: refusing to chown the repository root ($root)." >&2
                    echo "  Name the specific file or subdirectory instead." >&2
                    return 1
                end
                set -a targets $abs
            end

            # The owner is passed explicitly. `sudo chown` with no OWNER
            # changes the owner to ROOT — so this was doing the exact opposite
            # of "fix permissions" and leaving every named file root-owned.
            echo "about to chown to $USER: $targets"
            read -l -P 'proceed? [y/N] ' answer
            if not string match -qr '^y' -- "$answer"
                echo "cancelled."
                return 1
            end
            command sudo chown "$USER" -- $targets

        case '*'
            echo "usage: update_dotfiles <status|stage|unstage|review|commit|branch|push|pr|sync|fixperms>" >&2
            return 1
    end
end
