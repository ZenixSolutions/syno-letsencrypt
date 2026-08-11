#!/usr/bin/env bash
# schedule.sh — create and manage the DSM Task Scheduler entry.
#
# Why Task Scheduler rather than a systemd timer or cron
# ------------------------------------------------------
# A systemd timer works and is invisible. Cron is worse: DSM rewrites
# /etc/crontab and is strict about its formatting, so entries there quietly
# stop existing. Task Scheduler is where a Synology administrator looks to
# answer "what runs on this box?", and it lets them see the last run, the exit
# status, disable it, or run it on demand — without knowing this tool exists.
#
# Creation goes through synowebapi, the same mechanism used for the
# certificate: `synoschedtask` has --get, --del, --run and --sync, but no
# --add. The payload shape below is taken from the N4S4/synology-api library,
# which is a maintained implementation of this API.

# Kept in two steps: an apostrophe inside ${VAR:-default} is legal but parses
# as an unterminated quote to both linters and readers.
_SCHED_DEFAULT_NAME="Let's Encrypt renewal (syno-letsencrypt)"
SCHED_TASK_NAME="${SCHED_TASK_NAME:-${_SCHED_DEFAULT_NAME}}"
readonly SCHED_TASK_NAME
readonly SCHED_COMMAND="/usr/local/bin/syno-letsencrypt renew"

# Daily. repeat_date 1001 is the "daily" modality; week_day lists every day.
# The hour is randomised per install so that a fleet of NAS boxes running this
# does not hit Let's Encrypt in the same minute — Task Scheduler has no
# equivalent of systemd's RandomizedDelaySec.
sched_schedule_json() {
    local hour="$1" minute="$2"
    jq -nc --argjson h "${hour}" --argjson m "${minute}" \
        '{ date_type: 0, monthly_week: "[]", hour: $h, minute: $m,
           repeat_hour: 0, repeat_min: 0, last_work_hour: $h,
           week_day: "0,1,2,3,4,5,6", repeat_date: 1001 }'
}

sched_extra_json() {
    local email="${1:-}"
    local notify=false
    if [ -n "${email}" ]; then notify=true; fi
    # notify_if_error keeps the mail to actual failures rather than a daily
    # "nothing to do" message nobody will keep reading.
    jq -nc --arg s "${SCHED_COMMAND}" --arg m "${email}" --argjson n "${notify}" \
        '{ notify_enable: $n, notify_mail: $m, notify_if_error: true, script: $s }'
}

# sched_find_task_id — id of our task, or nothing. Matched on name, because
# DSM does not enforce unique task names and we must not stack duplicates on
# a re-install.
sched_find_task_id() {
    local out
    out="$(/usr/syno/bin/synowebapi --exec-fastwebapi \
        api=SYNO.Core.TaskScheduler method=list version=3 \
        offset=0 limit=200 2>/dev/null)" || return 0

    printf '%s' "${out}" \
        | jq -r --arg n "${SCHED_TASK_NAME}" \
            '.data.tasks[]? | select(.name == $n) | .id' 2>/dev/null \
        | head -n1
}

# sched_install [email] — create or update the task. Prints instructions and
# returns non-zero if DSM refuses, so the caller can fall back gracefully
# rather than leaving the user with no renewal at all.
sched_install() {
    local email="${1:-}"
    local existing hour minute schedule extra out api

    # Spread across the small hours rather than all landing at 03:00.
    hour=$(( RANDOM % 5 + 1 ))
    minute=$(( RANDOM % 60 ))

    existing="$(sched_find_task_id)"
    schedule="$(sched_schedule_json "${hour}" "${minute}")"
    extra="$(sched_extra_json "${email}")"

    # Root-owned tasks are created through the .Root variant. Over HTTP that
    # call also carries a password-confirmation token; invoked locally as root
    # it generally does not, but fall back to the plain API if it objects.
    for api in SYNO.Core.TaskScheduler.Root SYNO.Core.TaskScheduler; do
        local -a args=(
            --exec-fastwebapi
            "api=${api}" version=4
            "name=${SCHED_TASK_NAME}"
            real_owner=root owner=root
            enable=true type=script
            "schedule=${schedule}"
            "extra=${extra}"
        )
        if [ -n "${existing}" ]; then
            args+=(method=set "id=${existing}")
        else
            args+=(method=create)
        fi

        if out="$(/usr/syno/bin/synowebapi "${args[@]}" 2>&1)" \
           && printf '%s' "${out}" | jq -e '.success == true' >/dev/null 2>&1; then
            if [ -n "${existing}" ]; then
                log_info "Updated the Task Scheduler entry (id ${existing})."
            else
                log_info "Created a Task Scheduler entry, daily at $(printf '%02d:%02d' "${hour}" "${minute}")."
            fi
            log_info "Visible in Control Panel > Task Scheduler as: ${SCHED_TASK_NAME}"
            return 0
        fi
        log_debug "${api} failed: ${out}"
    done

    log_error "Could not create the Task Scheduler entry automatically."
    sched_manual_instructions "${hour}" "${minute}"
    return 1
}

sched_manual_instructions() {
    local hour="${1:-3}" minute="${2:-30}"
    cat >&2 <<TXT

Add it by hand instead — Control Panel > Task Scheduler:

    Create  >  Scheduled Task  >  User-defined script

    Task:      ${SCHED_TASK_NAME}
    User:      root
    Schedule:  daily, around $(printf '%02d:%02d' "${hour}" "${minute}")
    Run command:

        ${SCHED_COMMAND}

Without this the certificate will not renew itself.
TXT
}

# sched_remove — used by the uninstaller. synoschedtask does support --del.
sched_remove() {
    local id
    id="$(sched_find_task_id)"
    if [ -z "${id}" ]; then
        log_info "No Task Scheduler entry to remove."
        return 0
    fi
    if /usr/syno/bin/synoschedtask --del "id=${id}" >/dev/null 2>&1; then
        log_info "Removed Task Scheduler entry ${id}."
    else
        log_warn "Could not remove task ${id}. Delete '${SCHED_TASK_NAME}' in Control Panel > Task Scheduler."
    fi
}

# sched_status — one line for `syno-letsencrypt status`.
sched_status() {
    local id out
    id="$(sched_find_task_id)"
    if [ -z "${id}" ]; then
        printf 'Scheduled:    NO — renewal will not run. Re-run install.sh.\n'
        return 1
    fi
    out="$(/usr/syno/bin/synoschedtask --get "id=${id}" 2>/dev/null)" || true
    printf 'Scheduled:    yes (Task Scheduler id %s)\n' "${id}"
    printf '%s' "${out}" | sed -n 's/^\s*\(Last work time\|State\|Status\).*/              &/p' 2>/dev/null || true
    return 0
}
