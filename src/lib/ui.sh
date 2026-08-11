#!/usr/bin/env bash
# ui.sh — terminal presentation shared by the installer and the CLI.
#
# Everything here degrades to plain output when stdout is not a terminal, so
# piping to a log file or running from the scheduler produces readable text
# rather than a screenful of escape codes.

# Exported for callers; not all are used inside this file.
# shellcheck disable=SC2034
if [ -t 1 ]; then
    UI_TTY=true
    UI_RESET=$'\033[0m'; UI_BOLD=$'\033[1m'; UI_DIM=$'\033[2m'
    UI_BLUE=$'\033[38;5;39m'; UI_GREEN=$'\033[38;5;42m'
    UI_RED=$'\033[38;5;203m'; UI_YELLOW=$'\033[38;5;221m'
    UI_HIDE=$'\033[?25l'; UI_SHOW=$'\033[?25h'
else
    UI_TTY=false
    UI_RESET=""; UI_BOLD=""; UI_DIM=""
    UI_BLUE=""; UI_GREEN=""; UI_RED=""; UI_YELLOW=""
    UI_HIDE=""; UI_SHOW=""
fi

UI_LOGO="${UI_LOGO:-/usr/local/share/syno-letsencrypt/banner.txt}"

ui_cols() { tput cols 2>/dev/null || echo 80; }

# Deliberately not a RETURN trap: those are global in bash, not function-local,
# so one set here would fire on every later function return in the program.
# The caller installs this on EXIT/INT/TERM instead.
ui_cursor_restore() { [ "${UI_TTY}" = true ] && printf '%s' "${UI_SHOW}"; return 0; }

# ui_secs <seconds> — 95 -> "1m35s"
ui_secs() {
    local s="$1"
    if [ "${s}" -lt 60 ]; then printf '%ds' "${s}"
    else printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
    fi
}

# --------------------------------------------------------------------------
# The logo, filling left to right as a progress indicator
# --------------------------------------------------------------------------
#
# The wordmark is plain ASCII, so slicing it by byte is safe — unlike the
# spinner glyphs elsewhere, which are multi-byte and must not be sliced.

UI_LOGO_LINES=()
ui_logo_load() {
    if [ ${#UI_LOGO_LINES[@]} -gt 0 ]; then return 0; fi
    [ -r "${UI_LOGO}" ] || return 1
    local l
    while IFS= read -r l || [ -n "${l}" ]; do UI_LOGO_LINES+=("${l}"); done < "${UI_LOGO}"
    [ ${#UI_LOGO_LINES[@]} -gt 0 ]
}

ui_logo_height() { printf '%s' "${#UI_LOGO_LINES[@]}"; }

# ui_logo_draw <percent 0-100>
#
# Renders the wordmark with everything left of the fill point in colour and
# the remainder dimmed, so it reads as a progress bar shaped like the logo.
ui_logo_draw() {
    local pct="$1" line cut width=0 l
    for l in "${UI_LOGO_LINES[@]}"; do
        if [ "${#l}" -gt "${width}" ]; then width="${#l}"; fi
    done
    cut=$(( width * pct / 100 ))

    for line in "${UI_LOGO_LINES[@]}"; do
        # Pad so the fill boundary is a straight vertical edge across all rows.
        printf -v line '%-*s' "${width}" "${line}"
        printf '%s%s%s%s%s\n' \
            "${UI_BLUE}" "${line:0:cut}" \
            "${UI_DIM}"  "${line:cut}" "${UI_RESET}"
    done
}

# --------------------------------------------------------------------------
# Progress while an external command runs
# --------------------------------------------------------------------------

# ui_progress <pid> <logfile> <timeout_seconds>
#
# Watches a running command's log and renders progress until it exits. Written
# for lego, whose DNS-01 wait emits one identical line every two seconds for up
# to the propagation timeout — dozens of rows of noise that say nothing about
# how far along it is.
ui_progress() {
    local pid="$1" log="$2" timeout="$3"
    local stage="Starting" elapsed=0 pstart=0 pct=0 last="" height=0 drawn=false
    local narrow=false

    if [ "${UI_TTY}" != true ]; then
        wait "${pid}"; return $?
    fi

    ui_logo_load || narrow=true
    if [ "$(ui_cols)" -lt 104 ]; then narrow=true; fi
    if [ "${narrow}" = false ]; then height="$(ui_logo_height)"; fi

    printf '%s' "${UI_HIDE}"

    while kill -0 "${pid}" 2>/dev/null; do
        last="$(tail -n 40 "${log}" 2>/dev/null | grep -v '^$' | tail -n1)"

        case "${last}" in
            *"Obtaining bundled SAN certificate"*) stage="Requesting certificate" ;;
            *"Preparing to solve DNS-01"*)         stage="Preparing DNS challenge" ;;

            # The countdown starts the moment the record exists, not when lego
            # first mentions waiting. In --dns.propagation-wait mode lego says
            # nothing at all while it sleeps, so keying the fill on a
            # "Waiting for..." line would leave the logo frozen at zero for the
            # whole wait.
            *"new record for"*)
                stage="Waiting for DNS to propagate"
                if [ "${pstart}" -eq 0 ]; then pstart="${SECONDS}"; fi
                ;;
            *"Waiting for DNS record propagation"*|*"Checking DNS record propagation"*|*"Wait for propagation"*)
                stage="Waiting for DNS to propagate"
                if [ "${pstart}" -eq 0 ]; then pstart="${SECONDS}"; fi
                ;;
            *"Cleaning DNS-01 challenge"*)         stage="Cleaning up DNS record" ;;
            *"Server responded with a certificate"*) stage="Certificate issued" ;;
            *"Deactivating auth"*)                 stage="Rolling back" ;;
            *) ;;
        esac

        # Once the wait is over, lego is talking to Let's Encrypt. Say so rather
        # than leaving "waiting for DNS" on screen at 100%.
        if [ "${pstart}" -gt 0 ] && [ "${pct}" -ge 100 ] \
           && [ "${stage}" = "Waiting for DNS to propagate" ]; then
            stage="Validating with Let's Encrypt"
        fi

        if [ "${pstart}" -gt 0 ]; then
            elapsed=$(( SECONDS - pstart ))
            pct=$(( elapsed * 100 / timeout ))
            if [ "${pct}" -gt 100 ]; then pct=100; fi
        fi

        if [ "${narrow}" = false ]; then
            if [ "${drawn}" = true ]; then printf '\033[%dA' $(( height + 3 )); fi
            drawn=true
            printf '\033[2K\n'
            ui_logo_draw "${pct}"
            printf '\033[2K\n'
            if [ "${pstart}" -gt 0 ]; then
                printf '\033[2K   %s%s%s   %s%s elapsed, up to %s%s\n' \
                    "${UI_BOLD}" "${stage}" "${UI_RESET}" \
                    "${UI_DIM}" "$(ui_secs "${elapsed}")" "$(ui_secs "${timeout}")" "${UI_RESET}"
            else
                printf '\033[2K   %s%s%s\n' "${UI_BOLD}" "${stage}" "${UI_RESET}"
            fi
        else
            # Too narrow for the wordmark: one self-updating line.
            if [ "${pstart}" -gt 0 ]; then
                printf '\r\033[2K   %s%3d%%%s  %s  %s%s / %s%s' \
                    "${UI_BLUE}" "${pct}" "${UI_RESET}" "${stage}" \
                    "${UI_DIM}" "$(ui_secs "${elapsed}")" "$(ui_secs "${timeout}")" "${UI_RESET}"
            else
                printf '\r\033[2K   %s' "${stage}"
            fi
        fi

        sleep 1
    done

    wait "${pid}"
    local rc=$?

    if [ "${narrow}" = false ] && [ "${drawn}" = true ]; then
        printf '\033[%dA' $(( height + 3 ))
        printf '\033[J'                        # clear the animation away
    else
        printf '\r\033[2K'
    fi
    printf '%s' "${UI_SHOW}"
    return "${rc}"
}
