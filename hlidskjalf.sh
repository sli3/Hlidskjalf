#!/bin/bash
# --- Function: Centralized Error Handler ---
# Logs errors with timestamps and exit codes for diagnostic purposes
handle_error() {
    local EXIT_CODE=$1
    local CONTEXT=$2
    local TIMESTAMP=$(date '+%a %d %b %Y %H:%M:%S %p %Z')
    echo "[ERROR] ${TIMESTAMP} - Exit Code: ${EXIT_CODE} | Context: ${CONTEXT}" | sudo tee -a "$LOG_FILE" >&2
}

# --- Function: Safety Check for Sudo Privileges ---
# Checks if the current user has functional sudo privileges without needing an interactive password.
safety_check_sudo() {
    # Try running a non-interactive sudo command (e.g., 'sudo -n true').
    # The exit status ($?) will be 0 if sudo is available and accepts the command non-interactively.
    if sudo -n true 2>/dev/null; then
        return 0 # Success: Sudo privileges confirmed
    else
        echo "🚨 Sudo privileges are required but not available or configuration is incorrect. Exiting script."
        return 1 # Failure: Cannot proceed without sudo
    fi
}

# --- Function: Validate Docker Running State ---
# Checks if Docker daemon is running before cleanup operations
validate_docker() {
    if ! docker info >/dev/null 2>&1; then
        echo "[WARN] Docker is not running or not installed. Skipping Docker cleanup."
        return 1
    fi
    return 0
}

# --- Part 1: Logging Setup and Timestamp ---
# Define the log file location - CHANGED TO REFLECT SCRIPT NAME
LOG_FILE="/var/log/hlidskjalf.log"

# Run the timestamp command first. This creates/overwrites the log file
# and requires 'sudo' permissions.
if ! safety_check_sudo; then
    exit 1
fi

# --- Trap for Unexpected Exits ---
# Captures unexpected errors and logs them before exiting
trap 'handle_error $? "Unexpected script termination at line $LINENO"' ERR

# --- Part 2: The "Output Bucket" ---
# All output (stdout & stderr) from the block below will be
# appended to the log file, thanks to the redirection at the very end.
{
    # --- Configuration ---
    LOG_SIZE_LIMIT="50M" 
    LOG_TIME_LIMIT="7d"  
    set -e 

    echo "--- Starting Hlidskjalf Maintenance Run ---"
    
    # --- Dry-Run Setup ---
    if [ "$1" == "--dry-run" ]; then
        DRY_RUN_MODE=true
        echo "⚠️  RUNNING IN DRY-RUN MODE: No changes will be made. ⚠️"
    else
        DRY_RUN_MODE=false
    fi
    echo "--------------------------------------------------------"

    ## 🐳 Section 1: Docker Cleanup
    echo "1. Cleaning up unused Docker resources..."

    # Validate Docker is running before attempting cleanup
    if ! validate_docker; then
        echo "⚠️  Docker validation failed. Skipping Docker cleanup for safety."
        echo "--------------------------------------------------------"
    else
        # Docker is running, proceed with cleanup
        PRUNE_COMMANDS=(
            "docker image prune -a -f"
            "docker volume prune -f"
            "docker network prune -f"
            "docker builder prune -f"
        )

        for CMD in "${PRUNE_COMMANDS[@]}"; do
            
            if $DRY_RUN_MODE; then
                echo " [DRY RUN] Would execute: ${CMD}"
                continue 
            fi
            
            ERR_OUTPUT=$(eval $CMD 2>&1 || true) 
            EXIT_STATUS=$? 
            
            echo " -> Output for [${CMD}]:"
            echo "${ERR_OUTPUT}"
            
            if [ $EXIT_STATUS -ne 0 ] && [[ "$ERR_OUTPUT" != *"nothing to prune"* ]]; then
                echo "🚨 **CRITICAL ERROR** encountered during: ${CMD}"
                echo "   Exit Code: ${EXIT_STATUS}"
            fi
            echo ""
        done

        echo "✅ Docker cleanup finished."
        echo "--------------------------------------------------------"
    fi

    ## 🧹 Section 2: System Log Cleanup (Requires sudo)
    echo "2. Cleaning up old Ubuntu system logs and APT cache..."

    if $DRY_RUN_MODE; then
        echo " [DRY RUN] Would execute: sudo journalctl --vacuum-size=${LOG_SIZE_LIMIT} and time vacuum."
        echo " [DRY RUN] Would execute: sudo apt autoremove -y && sudo apt clean."
    else
        echo "Running Journalctl vacuum..."
sudo journalctl --vacuum-size="$LOG_SIZE_LIMIT"
sudo journalctl --vacuum-time="$LOG_TIME_LIMIT"

        echo "Running APT package cache cleanup..."
        sudo apt autoremove -y && sudo apt clean
    fi

    echo "✅ System log and APT cleanup finished."
    echo "--------------------------------------------------------"
    echo "🎉 Maintenance complete."

} 2>&1 | sudo tee -a $LOG_FILE # <-- LOG_FILE variable used here as well
