#!/usr/bin/env bash
#
# Hlidskjalf — Docker host maintenance
# Odin's high seat: see the state of your server, then set it right.
#
# Usage:  hlidskjalf.sh                 interactive menu
#         hlidskjalf.sh --all --yes     unattended (cron)
#         hlidskjalf.sh --help
#
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

readonly VERSION="2.0.0"
readonly SCRIPT_NAME="${0##*/}"

# ─────────────────────────────────────────────────────────────────────────────
# Configuration (override via environment or flags)
# ─────────────────────────────────────────────────────────────────────────────
LOG_FILE="${HLIDSKJALF_LOG:-/var/log/hlidskjalf.log}"
JOURNAL_SIZE_LIMIT="${HLIDSKJALF_JOURNAL_SIZE:-50M}"
JOURNAL_TIME_LIMIT="${HLIDSKJALF_JOURNAL_TIME:-7d}"
DOCKER_PRUNE_UNTIL="${HLIDSKJALF_PRUNE_UNTIL:-72h}"   # protect recent objects
BUILDER_KEEP="${HLIDSKJALF_BUILDER_KEEP:-2GB}"        # build cache to retain
DISK_TARGET="${HLIDSKJALF_DISK_TARGET:-/}"

DRY_RUN=false
ASSUME_YES=false
USE_COLOUR=true
NON_INTERACTIVE=false

# ─────────────────────────────────────────────────────────────────────────────
# Terminal / colour setup   (must run BEFORE stdout is redirected to the log)
# ─────────────────────────────────────────────────────────────────────────────
STDOUT_IS_TTY=false
[[ -t 1 ]] && STDOUT_IS_TTY=true
STDIN_IS_TTY=false
[[ -t 0 ]] && STDIN_IS_TTY=true
TERM_COLS=$(tput cols 2>/dev/null || echo 80)

setup_colours() {
    if [[ "$USE_COLOUR" == true && "$STDOUT_IS_TTY" == true && -z "${NO_COLOR:-}" ]]; then
        C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
        C_RED=$'\033[31m';  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m';  C_GREY=$'\033[90m'
        C_MAGENTA=$'\033[35m'
    else
        C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''
        C_BLUE=''; C_CYAN=''; C_GREY=''; C_MAGENTA=''
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Logging primitives
# ─────────────────────────────────────────────────────────────────────────────
log()      { printf '%s\n' "$*"; }
info()     { printf '%s\n' "${C_CYAN}  ›${C_RESET} $*"; }
ok()       { printf '%s\n' "${C_GREEN}  ✔${C_RESET} $*"; }
warn()     { printf '%s\n' "${C_YELLOW}  ⚠${C_RESET} $*"; }
err()      { printf '%s\n' "${C_RED}  ✖${C_RESET} $*" >&2; }
rule()     { printf '%s\n' "${C_GREY}$(printf '─%.0s' $(seq 1 $(( TERM_COLS > 78 ? 78 : TERM_COLS ))))${C_RESET}"; }
timestamp(){ date '+%Y-%m-%d %H:%M:%S %Z'; }

on_error() {
    local exit_code=$? line=${1:-?} cmd=${2:-?}
    err "Failure at line ${line}: '${cmd}' exited ${exit_code}"
    return 0
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

cleanup() {
    local rc=$?
    [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────────────────────
banner() {
    local wide=false
    [[ "$TERM_COLS" -ge 80 && "${LANG:-}${LC_ALL:-}" == *[Uu][Tt][Ff]* ]] && wide=true

    printf '\n'
    if [[ "$wide" == true ]]; then
        printf '%s' "${C_CYAN}${C_BOLD}"
        cat <<'BANNER'
 ██╗  ██╗██╗     ██╗██████╗ ███████╗██╗  ██╗     ██╗ █████╗ ██╗     ███████╗
 ██║  ██║██║     ██║██╔══██╗██╔════╝██║ ██╔╝     ██║██╔══██╗██║     ██╔════╝
 ███████║██║     ██║██║  ██║███████╗█████╔╝      ██║███████║██║     █████╗
 ██╔══██║██║     ██║██║  ██║╚════██║██╔═██╗ ██   ██║██╔══██║██║     ██╔══╝
 ██║  ██║███████╗██║██████╔╝███████║██║  ██╗╚█████╔╝██║  ██║███████╗██║
 ╚═╝  ╚═╝╚══════╝╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝ ╚════╝ ╚═╝  ╚═╝╚══════╝╚═╝
BANNER
        printf '%s' "${C_RESET}"
        printf '%s\n' "${C_GREY}   Odin's high seat · host maintenance · v${VERSION}${C_RESET}"
    else
        printf '%s\n' "${C_CYAN}${C_BOLD}=== HLIDSKJALF v${VERSION} ===${C_RESET}"
    fi
    printf '%s\n' "${C_GREY}   $(hostname) · $(timestamp)${C_RESET}"
    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# Convert a human size string ("1.84kB", "36 B", "2.1GiB") to bytes.
to_bytes() {
    awk -v v="$1" 'BEGIN{
        gsub(/,/,"",v)
        if (!match(v, /[0-9]+(\.[0-9]+)?/)) { print 0; exit }
        n = substr(v, RSTART, RLENGTH) + 0
        u = substr(v, RSTART + RLENGTH)
        gsub(/[ \t]/,"",u); u = toupper(u)
        m = 1
        if      (u=="KB"||u=="K") m = 1000
        else if (u=="MB")         m = 1000000
        else if (u=="GB")         m = 1000000000
        else if (u=="TB")         m = 1000000000000
        else if (u=="KIB")        m = 1024
        else if (u=="MIB")        m = 1048576
        else if (u=="GIB")        m = 1073741824
        else if (u=="TIB")        m = 1099511627776
        printf "%.0f", n * m
    }'
}

human_bytes() {
    awk -v b="$1" 'BEGIN{
        sign = (b < 0) ? "-" : ""; b = (b < 0) ? -b : b
        split("B KiB MiB GiB TiB", u, " ")
        i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%s%d %s", sign, b, u[i]
        else        printf "%s%.2f %s", sign, b, u[i]
    }'
}

avail_bytes() {
    local v=""
    # GNU coreutils: --output is mutually exclusive with -P, so query it alone.
    v=$( { df -B1 --output=avail "$DISK_TARGET" 2>/dev/null || true; } | tail -n1 | tr -cd '0-9')
    if [[ -z "$v" ]]; then
        # POSIX fallback (BusyBox, macOS, older df)
        v=$( { df -Pk "$DISK_TARGET" 2>/dev/null || true; } | awk 'NR==2 {printf "%.0f", $4 * 1024}')
    fi
    printf '%s' "${v:-0}"
}

disk_line() {
    df -h -P "$DISK_TARGET" | awk 'NR==2 {printf "size %s · used %s · free %s (%s used)", $2, $3, $4, $5}'
}

pkg_manager() {
    if   have apt-get; then echo apt
    elif have dnf;     then echo dnf
    elif have pacman;  then echo pacman
    else echo none
    fi
}

confirm() {
    [[ "$ASSUME_YES" == true ]] && return 0
    [[ "$STDIN_IS_TTY" == false ]] && return 1
    local reply
    read -r -p "${C_YELLOW}  ? ${C_RESET}$1 [y/N] " reply < /dev/tty
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Privilege handling
# ─────────────────────────────────────────────────────────────────────────────
ensure_sudo() {
    if [[ $EUID -eq 0 ]]; then SUDO=(); return 0; fi
    if ! have sudo; then err "sudo not found and not running as root."; return 1; fi
    SUDO=(sudo)

    if sudo -n true 2>/dev/null; then :
    elif [[ "$STDIN_IS_TTY" == true ]]; then
        info "Elevated privileges required."
        sudo -v || { err "Could not obtain sudo privileges."; return 1; }
    else
        err "Non-interactive run needs passwordless sudo (NOPASSWD) for this user."
        return 1
    fi

    # Keep the sudo timestamp warm for long prunes.
    ( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Task registry
# ─────────────────────────────────────────────────────────────────────────────
TASK_IDS=(containers images networks builder volumes images-all journal packages)

declare -A TASK_LABEL=(
    [containers]="Docker: stopped containers"
    [images]="Docker: dangling images"
    [networks]="Docker: unused networks"
    [builder]="Docker: build cache"
    [volumes]="Docker: unused volumes"
    [images-all]="Docker: ALL unused images"
    [journal]="System: journald vacuum"
    [packages]="System: package cache"
)
declare -A TASK_NOTE=(
    [containers]="older than ${DOCKER_PRUNE_UNTIL}"
    [images]="untagged layers only"
    [networks]="not attached to a container"
    [builder]="keeps ${BUILDER_KEEP}"
    [volumes]="DESTRUCTIVE — deletes data volumes"
    [images-all]="DESTRUCTIVE — re-pull required"
    [journal]="cap ${JOURNAL_SIZE_LIMIT}, keep ${JOURNAL_TIME_LIMIT}"
    [packages]="autoremove + clean"
)
declare -A TASK_RISK=(
    [containers]=safe [images]=safe [networks]=safe [builder]=safe
    [volumes]=danger [images-all]=danger [journal]=safe [packages]=safe
)
declare -A TASK_ON=(
    [containers]=1 [images]=1 [networks]=1 [builder]=1
    [volumes]=0 [images-all]=0 [journal]=1 [packages]=1
)

# Report accumulators
declare -A R_STATUS R_DETAIL R_SECONDS R_RECLAIMED
RUN_ORDER=()
FAILURES=0

# ─────────────────────────────────────────────────────────────────────────────
# Command runner — single place that handles dry-run, capture, timing, status
# ─────────────────────────────────────────────────────────────────────────────
run_cmd() {
    local -a cmd=("$@")
    local output status=0

    if [[ "$DRY_RUN" == true ]]; then
        printf '%s\n' "${C_MAGENTA}  ⟳ [dry-run]${C_RESET} ${cmd[*]}"
        LAST_OUTPUT=""
        return 0
    fi

    printf '%s\n' "${C_GREY}  $ ${cmd[*]}${C_RESET}"
    output=$("${cmd[@]}" 2>&1) || status=$?
    LAST_OUTPUT="$output"

    if [[ -n "$output" ]]; then
        printf '%s\n' "$output" | sed 's/^/    /'
    fi
    return "$status"
}

# Sum any "Total reclaimed space: X" lines from the last command output.
harvest_reclaimed() {
    local id=$1 line size total=0
    while IFS= read -r line; do
        size=$(printf '%s' "$line" | sed -n 's/.*Total reclaimed space:[[:space:]]*//p')
        [[ -n "$size" ]] && total=$(( total + $(to_bytes "$size") ))
    done <<< "${LAST_OUTPUT:-}"
    R_RECLAIMED[$id]=$(( ${R_RECLAIMED[$id]:-0} + total ))
}

# Wrap a task: header, timing, status capture. Never aborts the whole run.
run_task() {
    local id=$1 fn=$2 start=$SECONDS status=0

    RUN_ORDER+=("$id")
    R_RECLAIMED[$id]=0
    printf '\n%s\n' "${C_BOLD}${C_BLUE}▸ ${TASK_LABEL[$id]}${C_RESET} ${C_GREY}(${TASK_NOTE[$id]})${C_RESET}"

    if "$fn" "$id"; then status=0; else status=$?; fi
    R_SECONDS[$id]=$(( SECONDS - start ))

    case "${R_STATUS[$id]:-}" in
        skipped) warn "Skipped: ${R_DETAIL[$id]:-}" ;;
        *)
            if [[ $status -eq 0 ]]; then
                R_STATUS[$id]=ok
                ok "Done in ${R_SECONDS[$id]}s"
            else
                R_STATUS[$id]=failed
                R_DETAIL[$id]="exit ${status}"
                FAILURES=$(( FAILURES + 1 ))
                err "Failed (exit ${status})"
            fi
            ;;
    esac
    return 0
}

skip_task() { R_STATUS[$1]=skipped; R_DETAIL[$1]=$2; return 0; }

# ─────────────────────────────────────────────────────────────────────────────
# Task implementations
# ─────────────────────────────────────────────────────────────────────────────
docker_ready() {
    have docker || { echo "docker not installed"; return 1; }
    docker info >/dev/null 2>&1 || { echo "docker daemon not responding"; return 1; }
    return 0
}

task_docker_generic() {
    local id=$1; shift
    local reason
    if ! reason=$(docker_ready); then skip_task "$id" "$reason"; return 0; fi
    run_cmd "$@" || return $?
    harvest_reclaimed "$id"
}

task_containers() { task_docker_generic "$1" docker container prune -f --filter "until=${DOCKER_PRUNE_UNTIL}"; }
task_images()     { task_docker_generic "$1" docker image prune -f; }
task_networks()   { task_docker_generic "$1" docker network prune -f --filter "until=${DOCKER_PRUNE_UNTIL}"; }
task_builder()    { task_docker_generic "$1" docker builder prune -f --keep-storage "${BUILDER_KEEP}"; }

task_volumes() {
    local id=$1
    if ! confirm "Prune unused volumes? Any data in them is unrecoverable."; then
        skip_task "$id" "not confirmed"; return 0
    fi
    task_docker_generic "$id" docker volume prune -f
}

task_images_all() {
    local id=$1
    if ! confirm "Remove ALL unused images (not just dangling)? Images will need re-pulling."; then
        skip_task "$id" "not confirmed"; return 0
    fi
    task_docker_generic "$id" docker image prune -a -f --filter "until=${DOCKER_PRUNE_UNTIL}"
}

task_journal() {
    local id=$1 before='' after=''
    if ! have journalctl; then skip_task "$id" "journalctl not present"; return 0; fi

    journal_usage() {
        { "${SUDO[@]}" journalctl --disk-usage 2>/dev/null || true; } \
            | grep -oE '[0-9.]+[[:space:]]*[A-Za-z]+' | tail -n1
    }

    [[ "$DRY_RUN" == false ]] && before=$(journal_usage)
    run_cmd "${SUDO[@]}" journalctl --vacuum-size="$JOURNAL_SIZE_LIMIT" || return $?
    run_cmd "${SUDO[@]}" journalctl --vacuum-time="$JOURNAL_TIME_LIMIT" || return $?
    [[ "$DRY_RUN" == false ]] && after=$(journal_usage)

    if [[ -n "${before:-}" && -n "${after:-}" ]]; then
        R_RECLAIMED[$id]=$(( $(to_bytes "$before") - $(to_bytes "$after") ))
        R_DETAIL[$id]="journal ${before} → ${after}"
    fi
}

task_packages() {
    local id=$1 pm
    pm=$(pkg_manager)
    case "$pm" in
        apt)
            run_cmd "${SUDO[@]}" apt-get autoremove -y || return $?
            run_cmd "${SUDO[@]}" apt-get autoclean -y || return $?
            run_cmd "${SUDO[@]}" apt-get clean || return $?
            ;;
        dnf)
            run_cmd "${SUDO[@]}" dnf -y autoremove || return $?
            run_cmd "${SUDO[@]}" dnf -y clean packages || return $?
            ;;
        pacman)
            run_cmd bash -c 'pacman -Qtdq 2>/dev/null || true' || true
            run_cmd "${SUDO[@]}" pacman -Sc --noconfirm || return $?
            ;;
        *)  skip_task "$id" "no supported package manager"; return 0 ;;
    esac
    R_DETAIL[$id]="via ${pm}"
}

declare -A TASK_FN=(
    [containers]=task_containers
    [images]=task_images
    [networks]=task_networks
    [builder]=task_builder
    [volumes]=task_volumes
    [images-all]=task_images_all
    [journal]=task_journal
    [packages]=task_packages
)

# ─────────────────────────────────────────────────────────────────────────────
# Interactive menu
# ─────────────────────────────────────────────────────────────────────────────
draw_menu() {
    clear 2>/dev/null || true
    banner
    printf '%s\n' "${C_BOLD}  Select tasks${C_RESET} ${C_GREY}— type a number to toggle${C_RESET}"
    printf '\n'

    local i=1 id mark colour
    for id in "${TASK_IDS[@]}"; do
        if [[ ${TASK_ON[$id]} -eq 1 ]]; then mark="${C_GREEN}[x]${C_RESET}"; else mark="${C_GREY}[ ]${C_RESET}"; fi
        if [[ ${TASK_RISK[$id]} == danger ]]; then colour="$C_RED"; else colour="$C_RESET"; fi
        printf '   %s%2d%s %s %s%-30s%s %s%s%s\n' \
            "$C_BOLD" "$i" "$C_RESET" "$mark" "$colour" "${TASK_LABEL[$id]}" "$C_RESET" \
            "$C_GREY" "${TASK_NOTE[$id]}" "$C_RESET"
        i=$(( i + 1 ))
    done

    printf '\n'
    printf '   %sa%s all   %sn%s none   %ss%s safe-only   %sd%s dry-run: %s   %sv%s view disk   %sr%s RUN   %sq%s quit\n' \
        "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" \
        "$( [[ $DRY_RUN == true ]] && printf '%sON%s' "$C_MAGENTA" "$C_RESET" || printf 'off' )" \
        "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '\n'
    printf '   %s%s · %s%s\n\n' "$C_GREY" "$DISK_TARGET" "$(disk_line)" "$C_RESET"
}

menu_loop() {
    local choice id i
    while true; do
        draw_menu
        read -r -p "   ${C_CYAN}❯${C_RESET} " choice < /dev/tty || return 1
        case "$choice" in
            [0-9]*)
                if (( choice >= 1 && choice <= ${#TASK_IDS[@]} )); then
                    id="${TASK_IDS[$(( choice - 1 ))]}"
                    TASK_ON[$id]=$(( 1 - TASK_ON[$id] ))
                fi
                ;;
            a|A) for id in "${TASK_IDS[@]}"; do TASK_ON[$id]=1; done ;;
            n|N) for id in "${TASK_IDS[@]}"; do TASK_ON[$id]=0; done ;;
            s|S) for id in "${TASK_IDS[@]}"; do
                     [[ ${TASK_RISK[$id]} == safe ]] && TASK_ON[$id]=1 || TASK_ON[$id]=0
                 done ;;
            d|D) [[ $DRY_RUN == true ]] && DRY_RUN=false || DRY_RUN=true ;;
            v|V) clear 2>/dev/null || true
                 printf '\n%s\n\n' "${C_BOLD}Disk usage${C_RESET}"
                 df -h -P | sed 's/^/  /'
                 if docker_ready >/dev/null 2>&1; then
                     printf '\n%s\n\n' "${C_BOLD}Docker usage${C_RESET}"
                     docker system df | sed 's/^/  /'
                 fi
                 read -r -p $'\n  Press Enter to return… ' _ < /dev/tty
                 ;;
            r|R|"") 
                for id in "${TASK_IDS[@]}"; do [[ ${TASK_ON[$id]} -eq 1 ]] && return 0; done
                printf '   %sNothing selected.%s\n' "$C_YELLOW" "$C_RESET"; sleep 1
                ;;
            q|Q) log "Aborted by user."; exit 0 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Report
# ─────────────────────────────────────────────────────────────────────────────
print_report() {
    local before=$1 after=$2 id total=0 delta status_txt colour
    delta=$(( after - before ))

    printf '\n'
    rule
    printf '%s\n' "${C_BOLD}  MAINTENANCE REPORT${C_RESET}  ${C_GREY}$(timestamp)${C_RESET}"
    rule
    printf '  %-32s %-9s %8s %14s\n' "TASK" "STATUS" "TIME" "RECLAIMED"

    for id in "${RUN_ORDER[@]}"; do
        case "${R_STATUS[$id]:-unknown}" in
            ok)      colour="$C_GREEN";  status_txt="ok" ;;
            skipped) colour="$C_YELLOW"; status_txt="skipped" ;;
            failed)  colour="$C_RED";    status_txt="FAILED" ;;
            *)       colour="$C_GREY";   status_txt="unknown" ;;
        esac
        total=$(( total + ${R_RECLAIMED[$id]:-0} ))
        printf '  %-32s %s%-9s%s %7ss %14s\n' \
            "${TASK_LABEL[$id]}" "$colour" "$status_txt" "$C_RESET" \
            "${R_SECONDS[$id]:-0}" "$(human_bytes "${R_RECLAIMED[$id]:-0}")"
        [[ -n "${R_DETAIL[$id]:-}" ]] && printf '  %s└─ %s%s\n' "$C_GREY" "${R_DETAIL[$id]}" "$C_RESET"
    done

    rule
    printf '  %-32s %26s\n' "Reported reclaimed by tools" "$(human_bytes "$total")"
    printf '  %-32s %26s\n' "Free on ${DISK_TARGET} (before)" "$(human_bytes "$before")"
    printf '  %-32s %26s\n' "Free on ${DISK_TARGET} (after)"  "$(human_bytes "$after")"
    printf '  %s%-32s %26s%s\n' "$C_BOLD" "Net change in free space" "$(human_bytes "$delta")" "$C_RESET"
    rule

    if [[ "$DRY_RUN" == true ]]; then
        printf '%s\n' "${C_MAGENTA}  DRY RUN — nothing was changed.${C_RESET}"
    fi
    if [[ $FAILURES -gt 0 ]]; then
        printf '%s\n' "${C_RED}  ${FAILURES} task(s) failed. See ${LOG_FILE}${C_RESET}"
    else
        printf '%s\n' "${C_GREEN}  All selected tasks completed.${C_RESET}"
    fi
    printf '%s\n\n' "${C_GREY}  Log: ${LOG_FILE}${C_RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${C_BOLD}Hlidskjalf${C_RESET} v${VERSION} — Docker host maintenance

  ${C_BOLD}Usage${C_RESET}
    ${SCRIPT_NAME} [options]

  ${C_BOLD}Options${C_RESET}
    -t, --tasks LIST     Comma-separated task IDs to run (implies non-interactive)
    -a, --all            Select every task, including destructive ones
    -s, --safe           Select only non-destructive tasks
    -y, --yes            Assume yes to confirmations (required for cron)
    -d, --dry-run        Show what would run, change nothing
        --log FILE       Log file (default: ${LOG_FILE})
        --until DUR      Protect Docker objects newer than this (default: ${DOCKER_PRUNE_UNTIL})
        --keep SIZE      Build cache to retain (default: ${BUILDER_KEEP})
        --no-color       Disable colour output
    -h, --help           This help
    -v, --version        Print version

  ${C_BOLD}Task IDs${C_RESET}
    $(printf '%s ' "${TASK_IDS[@]}")

  ${C_BOLD}Examples${C_RESET}
    ${SCRIPT_NAME}                                  # interactive menu
    ${SCRIPT_NAME} --safe --yes                     # unattended safe cleanup
    ${SCRIPT_NAME} -t containers,images,journal -y
    ${SCRIPT_NAME} --all --dry-run

  ${C_BOLD}Cron${C_RESET}
    0 4 * * 0  /usr/local/bin/${SCRIPT_NAME} --safe --yes >/dev/null 2>&1
    (requires passwordless sudo for journalctl/apt-get)
EOF
}

# Usage errors: report cleanly and exit 2, never via the ERR trap.
die() {
    printf '%s\n' "${C_RED}error:${C_RESET} $*" >&2
    printf '%s\n' "Try '${SCRIPT_NAME} --help'." >&2
    exit 2
}

# need_arg <flag> [next-arg] — fails if the option's value is missing or is
# itself another option.
need_arg() {
    local flag=$1 val=${2-}
    [[ -n "$val" && "$val" != -* ]] || die "option '${flag}' requires a value."
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--tasks)
                need_arg "$1" "${2-}"
                local id found
                for id in "${TASK_IDS[@]}"; do TASK_ON[$id]=0; done
                local -a _req=()
                IFS=',' read -ra _req <<< "$2"
                local req
                for req in "${_req[@]}"; do
                    [[ -n "$req" ]] || continue
                    found=false
                    for id in "${TASK_IDS[@]}"; do
                        [[ "$id" == "$req" ]] && { TASK_ON[$id]=1; found=true; }
                    done
                    [[ "$found" == false ]] && die "unknown task '${req}'. Valid: ${TASK_IDS[*]}"
                done
                for id in "${TASK_IDS[@]}"; do
                    [[ ${TASK_ON[$id]} -eq 1 ]] && found=selected
                done
                [[ "${found:-}" == selected ]] || die "--tasks selected nothing. Valid: ${TASK_IDS[*]}"
                NON_INTERACTIVE=true; shift 2 ;;
            -a|--all)
                local id; for id in "${TASK_IDS[@]}"; do TASK_ON[$id]=1; done
                NON_INTERACTIVE=true; shift ;;
            -s|--safe)
                local id
                for id in "${TASK_IDS[@]}"; do
                    [[ ${TASK_RISK[$id]} == safe ]] && TASK_ON[$id]=1 || TASK_ON[$id]=0
                done
                NON_INTERACTIVE=true; shift ;;
            -y|--yes)      ASSUME_YES=true; shift ;;
            -d|--dry-run)  DRY_RUN=true; shift ;;
            --log)         need_arg "$1" "${2-}"; LOG_FILE="$2"; shift 2 ;;
            --until)       need_arg "$1" "${2-}"; DOCKER_PRUNE_UNTIL="$2"; shift 2 ;;
            --keep)        need_arg "$1" "${2-}"; BUILDER_KEEP="$2"; shift 2 ;;
            --no-color|--no-colour) USE_COLOUR=false; shift ;;
            -h|--help)     setup_colours; usage; exit 0 ;;
            -v|--version)  echo "${SCRIPT_NAME} ${VERSION}"; exit 0 ;;
            --)            shift ;;
            *)             die "unknown option '$1'." ;;
        esac
    done
}

init_logging() {
    if [[ ! -w "$LOG_FILE" ]]; then
        "${SUDO[@]}" touch "$LOG_FILE" 2>/dev/null || true
        "${SUDO[@]}" chown "$(id -u):$(id -g)" "$LOG_FILE" 2>/dev/null || true
    fi
    if [[ -w "$LOG_FILE" ]]; then
        # Tee to terminal and to a colour-stripped copy in the log.
        exec > >(tee >(sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE")) 2>&1
    else
        LOG_FILE="(unavailable — output not persisted)"
    fi
}

main() {
    setup_colours
    parse_args "$@"
    setup_colours

    [[ "$STDIN_IS_TTY" == false ]] && NON_INTERACTIVE=true

    ensure_sudo || exit 1
    init_logging

    if [[ "$NON_INTERACTIVE" == false ]]; then
        menu_loop || exit 0
        clear 2>/dev/null || true
    fi

    banner
    printf '%s\n' "${C_GREY}  Mode: $( [[ $DRY_RUN == true ]] && echo 'DRY RUN' || echo 'live' ) · ${DISK_TARGET}: $(disk_line)${C_RESET}"

    local before after id
    before=$(avail_bytes)

    for id in "${TASK_IDS[@]}"; do
        [[ ${TASK_ON[$id]} -eq 1 ]] || continue
        run_task "$id" "${TASK_FN[$id]}"
    done

    after=$(avail_bytes)
    print_report "$before" "$after"

    # Give the tee subprocess a moment to flush before the shell exits.
    sleep 0.2
    [[ $FAILURES -gt 0 ]] && exit 1
    exit 0
}

main "$@"