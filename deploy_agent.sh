#!/usr/bin/env bash
# =============================================================================
# deploy_agent.sh - Student Attendance Tracker bootstrapper
#
# Features:
#   1) Deploy   : create project structure, populate files, set permissions,
#                 optionally update thresholds, then verify by running the app
#   2) Run      : run attendance_checker.py in an already deployed project
#   3) Archive  : archive reports/*.log into timestamped files
#
# Usage:
#   ./deploy_agent.sh             interactive menu
#   ./deploy_agent.sh --deploy    (or -d)
#   ./deploy_agent.sh --run       (or -r)
#   ./deploy_agent.sh --archive   (or -a)
#   ./deploy_agent.sh --help      (or -h)
# =============================================================================

# Absolute path of the folder holding this script, so it works from any directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

# Globals shared with the signal handler (it needs to know what to clean up)
PROJECT_DIR=""        # e.g. attendance_tracker_demo (relative to SCRIPT_DIR)
DEPLOYING=0           # 1 while Feature 1 is in progress

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*" >&2; }
err()   { echo "[ERROR] $*" >&2; }

# read wrapper: stop cleanly if input ends (EOF) instead of looping forever
ask_read() {
    read "$@" && return 0
    echo
    if [ "$DEPLOYING" -eq 1 ]; then
        handle_interrupt "end of input"
    fi
    err "Input ended unexpectedly."
    exit 1
}

is_positive_int() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ]; }

# Ask for a project name and set PROJECT_DIR.
# Only letters, digits, ".", "_" and "-" are allowed, which blocks spaces,
# slashes and "..", so a typo can never create or delete the wrong path.
ask_project_name() {
    local input
    ask_read -r -p "Enter project name (directory will be attendance_tracker_<name>): " input
    if [[ -z "$input" || ! "$input" =~ ^[A-Za-z0-9_.-]+$ || "$input" == "." || "$input" == ".." ]]; then
        err "Invalid name. Use letters, digits, '.', '_' or '-' only (no spaces or slashes)."
        return 1
    fi
    PROJECT_DIR="attendance_tracker_${input}"
    return 0
}

# ----------------------------------------------------------------------------
# Signal handling (Ctrl+C = SIGINT, Ctrl+Z = SIGTSTP) - active during deploy
# ----------------------------------------------------------------------------
# Runs when SIGINT/SIGTSTP (or end of input) arrives during deployment:
# 1) report it, 2) zip whatever exists so far, 3) delete the half-made
# directory, 4) exit cleanly.
handle_interrupt() {
    local sig="$1"
    # Ignore further signals while we clean up
    trap '' INT TSTP
    echo
    echo "=============================================================="
    echo "[INTERRUPTED] Deployment was interrupted by $sig."
    echo "=============================================================="

    cd "$SCRIPT_DIR" || true

    if [[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]]; then
        local zipfile="${PROJECT_DIR}_archive.zip"
        info "Archiving the incomplete project into $zipfile ..."
        if zip -rq "$zipfile" "$PROJECT_DIR"; then
            ok "Archive created: $SCRIPT_DIR/$zipfile"
            rm -rf "$PROJECT_DIR"
            ok "Removed incomplete directory $PROJECT_DIR."
        else
            err "Could not create the archive; leaving $PROJECT_DIR in place."
        fi
    else
        info "No project directory had been created yet; nothing to archive."
    fi

    echo "Session closed cleanly."
    exit 130
}

# Traps are switched on only while deploying, and off before the app runs,
# so they never interfere with the marking session in attendance_checker.py.
enable_traps()  {
    trap 'handle_interrupt SIGINT'  INT
    trap 'handle_interrupt SIGTSTP' TSTP
}
disable_traps() { trap - INT TSTP; }

# ----------------------------------------------------------------------------
# Feature 2: Run the application
# ----------------------------------------------------------------------------
# Run the app from inside the project folder, because attendance_checker.py
# reads its files via fixed relative paths (Helpers/..., reports/...).
# Takes a project dir, or asks for one if called with an empty argument.
run_app() {
    local dir="$1"
    if [[ -z "$dir" ]]; then
        ask_project_name || return 1
        dir="$PROJECT_DIR"
    fi
    if [[ ! -f "$SCRIPT_DIR/$dir/attendance_checker.py" ]]; then
        err "No deployed project found at '$dir'. Deploy it first (feature 1)."
        return 1
    fi
    info "Starting the Attendance Tracker in $dir ..."
    # Subshell: the cd does not change this script's own working directory
    ( cd "$SCRIPT_DIR/$dir" && python3 attendance_checker.py )
    local rc=$?
    if [ $rc -eq 0 ]; then
        ok "Application exited successfully."
    else
        err "Application exited with status $rc."
    fi
    return $rc
}

# ----------------------------------------------------------------------------
# Feature 3: Archive the logs
# ----------------------------------------------------------------------------
archive_logs() {
    ask_project_name || return 1
    local dir="$SCRIPT_DIR/$PROJECT_DIR"
    if [[ ! -d "$dir" ]]; then
        err "Project '$PROJECT_DIR' does not exist."
        return 1
    fi

    # One timestamp for the whole run so both logs share the same suffix
    local ts archived=0 missing=0 name src dest_dir dest
    ts="$(date +%Y%m%d_%H%M%S)"

    for name in attendance absent; do
        src="$dir/reports/${name}.log"
        dest_dir="$dir/archives/${name}"
        dest="$dest_dir/${name}_${ts}.log"
        # A missing log (e.g. nobody was absent) is reported, not treated as a crash
        if [[ -f "$src" ]]; then
            mkdir -p "$dest_dir" || { err "Cannot create $dest_dir"; continue; }
            if cp "$src" "$dest"; then
                ok "Archived ${name}.log -> $PROJECT_DIR/archives/${name}/${name}_${ts}.log"
                archived=$((archived + 1))
            else
                err "Failed to archive $src"
            fi
        else
            warn "reports/${name}.log not found (skipped)."
            missing=$((missing + 1))
        fi
    done

    echo "Summary: $archived archived, $missing missing."
    if [ "$archived" -eq 0 ]; then
        info "Nothing to archive. Run the application first (feature 2)."
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Feature 1: Deploy
# ----------------------------------------------------------------------------
# Fail early with a clear message if a required tool or template is missing
preflight_checks() {
    local missing=0 cmd
    for cmd in python3 zip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            err "Required command '$cmd' is not installed or not in PATH."
            missing=1
        fi
    done
    if [ $missing -ne 0 ]; then
        err "Pre-flight checks failed. Install the missing tools and retry."
        return 1
    fi
    for f in attendance_checker.py assets.csv config.json; do
        if [[ ! -f "$TEMPLATES_DIR/$f" ]]; then
            err "Missing template: $TEMPLATES_DIR/$f"
            return 1
        fi
    done
    ok "Pre-flight checks passed (python3, zip, templates found)."
}

# Option B data
NAMES=("Alice Johnson" "Bob Smith" "Carol White" "David Brown" "Eve Davis"
       "Frank Miller" "Grace Wilson" "Henry Moore" "Irene Taylor" "Jack Anderson"
       "Karen Thomas" "Leo Jackson" "Mia Harris" "Noah Martin" "Olivia Clark")
EMAILS=("alice" "bob" "carol" "david" "eve"
        "frank" "grace" "henry" "irene" "jack"
        "karen" "leo" "mia" "noah" "olivia")

# Option B: build a roster of $1 students into file $2, counts starting at 0.
# Past 15 students the sample names repeat with a number so emails stay unique.
generate_roster() {
    local count="$1" out="$2" i idx round
    echo "Email,Names,Attendance Count,Absence Count" > "$out"
    for ((i = 0; i < count; i++)); do
        idx=$((i % ${#NAMES[@]}))
        round=$((i / ${#NAMES[@]}))
        if [ "$round" -eq 0 ]; then
            echo "${EMAILS[$idx]}@example.com,${NAMES[$idx]},0,0" >> "$out"
        else
            # Keep emails unique if more students than sample names
            echo "${EMAILS[$idx]}${round}@example.com,${NAMES[$idx]} ${round},0,0" >> "$out"
        fi
    done
}

# Optionally change the warning/failure percentages in the deployed config.json.
# Only those two values are touched (via sed), so the file layout is unchanged.
update_thresholds() {
    local cfg="$1" warning failure
    ask_read -r -p "Update attendance alert thresholds in config.json? (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "Keeping default thresholds."; return 0; }

    while true; do
        ask_read -r -p "  Warning threshold % [75]: " warning
        warning="${warning:-75}"
        ask_read -r -p "  Failure threshold % [50]: " failure
        failure="${failure:-50}"
        if [[ "$warning" =~ ^[0-9]+$ && "$failure" =~ ^[0-9]+$ ]] \
           && [ "$warning" -le 100 ] && [ "$failure" -le 100 ] \
           && [ "$failure" -lt "$warning" ]; then
            break
        fi
        warn "Enter whole numbers 0-100, with failure lower than warning."
    done

    # Edit only the two target lines in place; keeps layout and order intact
    sed -i.bak -E \
        -e "s/(\"warning\"[[:space:]]*:[[:space:]]*)[0-9]+/\1${warning}/" \
        -e "s/(\"failure\"[[:space:]]*:[[:space:]]*)[0-9]+/\1${failure}/" \
        "$cfg" && rm -f "${cfg}.bak"
    ok "Thresholds updated: warning=${warning}, failure=${failure}"
}

# Feature 1: build a new project end to end, then verify it by running the app
deploy() {
    preflight_checks || return 1
    ask_project_name || return 1

    # Overwrite protection (runs before any traps matter: nothing created yet)
    if [[ -e "$SCRIPT_DIR/$PROJECT_DIR" ]]; then
        warn "Directory '$PROJECT_DIR' already exists."
        ask_read -r -p "Overwrite it? (y/N): " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            rm -rf "${SCRIPT_DIR:?}/$PROJECT_DIR"
        else
            err "Aborted: existing project left untouched."
            return 1
        fi
    fi

    DEPLOYING=1
    enable_traps
    cd "$SCRIPT_DIR" || return 1

    info "Creating directory structure..."
    mkdir -p "$PROJECT_DIR/Helpers" "$PROJECT_DIR/reports" || { err "mkdir failed"; return 1; }

    info "Copying application files..."
    cp "$TEMPLATES_DIR/attendance_checker.py" "$PROJECT_DIR/attendance_checker.py" || return 1
    cp "$TEMPLATES_DIR/config.json" "$PROJECT_DIR/Helpers/config.json" || return 1

    # --- Roster: A = copy rows from the template, B = generate fresh rows ---
    local choice count total_sessions avail
    echo "How should the student roster be built?"
    echo "  A) Copy rows from templates/assets.csv (4 prior sessions each)"
    echo "  B) Generate a fresh roster (counts start at 0)"
    while true; do
        ask_read -r -p "Choose A or B: " choice
        [[ "$choice" =~ ^[AaBb]$ ]] && break
        warn "Please enter A or B."
    done

    if [[ "$choice" =~ ^[Aa]$ ]]; then
        avail=$(awk 'END{print NR-1}' "$TEMPLATES_DIR/assets.csv")
        while true; do
            ask_read -r -p "How many students to copy (1-${avail})? " count
            if is_positive_int "$count" && [ "$count" -le "$avail" ]; then break; fi
            warn "Enter a whole number between 1 and ${avail}."
        done
        # +1 keeps the header row
        head -n $((count + 1)) "$TEMPLATES_DIR/assets.csv" > "$PROJECT_DIR/Helpers/assets.csv"
        total_sessions=5
    else
        while true; do
            ask_read -r -p "How many students to generate (1-100)? " count
            if is_positive_int "$count" && [ "$count" -le 100 ]; then break; fi
            warn "Enter a whole number between 1 and 100."
        done
        generate_roster "$count" "$PROJECT_DIR/Helpers/assets.csv"
        total_sessions=1
    fi
    ok "Roster created with $count students."

    # Rule: total_sessions = prior sessions in the roster + 1 (today).
    # Keep total_sessions consistent with the roster (prior sessions + 1)
    sed -i.bak -E "s/(\"total_sessions\"[[:space:]]*:[[:space:]]*)[0-9]+/\1${total_sessions}/" \
        "$PROJECT_DIR/Helpers/config.json" && rm -f "$PROJECT_DIR/Helpers/config.json.bak"
    info "total_sessions set to $total_sessions to match the roster."

    # --- Thresholds ---
    update_thresholds "$PROJECT_DIR/Helpers/config.json"

    # --- Permissions: script executable, config readable/writable by owner only ---
    chmod +x "$PROJECT_DIR/attendance_checker.py"
    chmod 600 "$PROJECT_DIR/Helpers/config.json"
    echo "Permissions set:"
    ls -l "$PROJECT_DIR/attendance_checker.py" "$PROJECT_DIR/Helpers/config.json" \
        | awk '{print "  " $1 "  " $NF}'

    # Deployment finished: signals are no longer trapped from here on
    DEPLOYING=0
    disable_traps
    ok "Deployment of $PROJECT_DIR complete."

    # --- Verify by running the app (Feature 2) ---
    info "Verifying deployment by launching the application..."
    run_app "$PROJECT_DIR"
}

# ----------------------------------------------------------------------------
# Menu / entry point
# ----------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [option]
  -d, --deploy    Deploy a new project
  -r, --run       Run an already deployed project
  -a, --archive   Archive reports/*.log of a project
  -h, --help      Show this help
With no option, an interactive menu is shown.
EOF
}

# Interactive menu (used when the script is run with no arguments)
menu() {
    while true; do
        echo
        echo "===== Attendance Tracker Deploy Agent ====="
        echo "1) Deploy the application"
        echo "2) Run the application"
        echo "3) Archive the log files"
        echo "4) Exit"
        ask_read -r -p "Select an option [1-4]: " opt
        case "$opt" in
            1) deploy ;;
            2) run_app "" ;;
            3) archive_logs ;;
            4) echo "Goodbye."; exit 0 ;;
            *) warn "Invalid option." ;;
        esac
    done
}

case "${1:-}" in
    -d|--deploy)  deploy ;;
    -r|--run)     run_app "" ;;
    -a|--archive) archive_logs ;;
    -h|--help)    usage ;;
    "")           menu ;;
    *)            err "Unknown option: $1"; usage; exit 1 ;;
esac
