function merge_dev_into_master -d "Merge dev into master, accepting 'dev' changes for conflicts"
    # Check if a commit message argument is provided
    if test (count $argv) -lt 1
        echo "Error: No commit message provided."
        return 1
    end

    set commit_message $argv[1]
    set original_pull_rebase_config (git config --global --get pull.rebase)

    # Set pull.rebase to false temporarily if not doing globally
    git config pull.rebase false --global

    # Stashing any uncommitted changes
    git stash

    # Checkout to master and merge from dev
    git checkout master
    git pull origin master
    git pull origin dev

    # List all conflicted files and accept changes from dev
    for file in (git diff --name-only --diff-filter=U)
        git checkout --theirs $file
        git add $file
    end

    # Commit the merge
    git commit -m "$commit_message"

    # Push changes
    git push origin master

    # Checkout back to dev
    git checkout dev

    # Reset pull.rebase to its original setting if it was modified temporarily
    if test -n "$original_pull_rebase_config"
        git config pull.rebase $original_pull_rebase_config --global
    else
        git config --global --unset pull.rebase
    end

    # Apply stashed changes if there were any
    git stash pop
end
