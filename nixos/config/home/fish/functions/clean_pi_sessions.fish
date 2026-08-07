function clean_pi_sessions -d "Cleanup Pi agent session files and subagent artifacts older than 14 days"
    set -l session_dir "$HOME/.pi/agent/sessions"
    set -l db_path "$HOME/.pi/context-mode/sessions/context-mode.db"
    
    if not test -d "$session_dir"
        echo (set_color red)"[Error]" (set_color normal)"Session directory not found: $session_dir"
        return 1
    end

    echo (set_color yellow)"==> Scanning for Pi sessions and artifacts older than 14 days..."(set_color normal)
    
    # Find all files older than 14 days
    set -l old_files (find "$session_dir" -type f -mtime +14)
    
    if test -z "$old_files"
        echo (set_color green)"[Clean]" (set_color normal)"No session files or artifacts older than 14 days found."
    else
        echo (set_color red)"[Found]"(set_color normal) (count $old_files) "files older than 14 days."
        for file in $old_files
            echo "  - "(basename $file) "("(du -h $file | cut -f1)")"
        end
        
        echo -n "Delete these files? [y/N]: "
        read -l confirm
        if test "$confirm" = "y" -o "$confirm" = "Y"
            for file in $old_files
                rm -f "$file"
            end
            # Remove empty directories
            find "$session_dir" -type d -empty -delete
            echo (set_color green)"[Success]" (set_color normal)"Deleted old session files."
        else
            echo (set_color yellow)"[Skipped]" (set_color normal)"No files deleted."
        end
    end

    # Run SQLite VACUUM on context-mode.db if it exists to optimize indexes
    if test -f "$db_path"
        echo (set_color yellow)"==> Optimizing and vacuuming context-mode.db..."(set_color normal)
        sqlite3 "$db_path" "VACUUM; ANALYZE;"
        echo (set_color green)"[Success]" (set_color normal)"SQLite database vacuumed and optimized."
    end
end
