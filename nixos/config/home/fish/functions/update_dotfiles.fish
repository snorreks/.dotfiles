function update_dotfiles
    set TARGET_DIR "$HOME/.dotfiles"

    # Fix permissions
    sudo chown -R sonny:users $TARGET_DIR
    echo "Permissions have been fixed for $TARGET_DIR"

    # Commit changes
    set commit_message $argv[1]
    if test -z "$commit_message"
        set commit_message "fix"
    end

    cd $TARGET_DIR
    git add -A
    git commit -m $commit_message

    # Push changes
    git push origin master
end
