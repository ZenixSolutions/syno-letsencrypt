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
_SCHED_DEFAULT_NAME="Let's Encrypt renewal (zenix-cert)"
SCHED_TASK_NAME="${SCHED_TASK_NAME:-${_SCHED_DEFAULT_NAME}}"
readonly SCHED_TASK_NAME
readonly SCHED_COMMAND="/usr/local/bin/zenix-cert renew"

# Task names used before the command was renamed away from syno-letsencrypt,
# which collided with DSM's own command of that name. Matching is by name, so
# without this an upgrade would leave the old task in place and add a second
# one beside it — two renewals a day, one of them pointing at a binary that no
# longer exists.
readonly SCHED_LEGACY_NAME="Let's Encrypt renewal (syno-letsencrypt)"

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

# The task list, fetched once. Several checks below need it and each
# synowebapi call costs the better part of a second.
_SCHED_LIST_CACHE=""
sched_list_json() {
    if [ -z "${_SCHED_LIST_CACHE}" ]; then
        _SCHED_LIST_CACHE="$(/usr/syno/bin/synowebapi --exec-fastwebapi \
            api=SYNO.Core.TaskScheduler method=list version=3 \
            offset=0 limit=200 2>/dev/null | sed -n '/^[[:space:]]*{/,$p')"
    fi
    printf '%s' "${_SCHED_LIST_CACHE}"
}
sched_list_invalidate() { _SCHED_LIST_CACHE=""; }

# sched_find_task_id [name] — id of a task by name, or nothing. Matched on name
# because DSM does not enforce unique task names and we must not stack
# duplicates on a re-install.
sched_find_task_id() {
    local want="${1:-${SCHED_TASK_NAME}}"
    sched_list_json \
        | jq -r --arg n "${want}" \
            '.data.tasks[]? | select(.name == $n) | .id' 2>/dev/null \
        | head -n1
}

# sched_find_ours — every task that actually invokes this tool.
#   <id> current   runs zenix-cert
#   <id> stale     runs the old syno-letsencrypt command, which is gone
#
# Names are not sufficient evidence. A task created before the rename still
# exists, still shows as enabled in Control Panel, still looks entirely
# healthy — and calls /usr/local/bin/syno-letsencrypt, which the installer
# removes. It fails silently at 1am, which is strictly worse than no task at
# all, because nothing ever prompts anyone to look.
#
# Deliberately format-agnostic: both the task's JSON and the raw output of
# `synoschedtask --get` are searched as plain text. DSM has moved where the
# script body lives between releases, and a check that quietly stops finding
# the task is precisely the failure this exists to catch.
sched_find_ours() {
    local ids id blob
    ids="$(sched_list_json | jq -r '.data.tasks[]?.id' 2>/dev/null)"
    for id in ${ids}; do
        blob="$(sched_list_json | jq -c --arg i "${id}" \
                  '.data.tasks[]? | select((.id|tostring) == $i)' 2>/dev/null)"
        blob="${blob}$(/usr/syno/bin/synoschedtask --get "id=${id}" 2>/dev/null)"
        case "${blob}" in
            *zenix-cert*)       printf '%s current\n' "${id}" ;;
            *syno-letsencrypt*) printf '%s stale\n'   "${id}" ;;
            *) ;;
        esac
    done
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

    # The list is cached; anything below changes it.
    sched_list_invalidate

    # Clear out a task left by the pre-rename version before adding ours.
    # Matched by command rather than by name, since the name is exactly what
    # a hand-edited or renamed task will not have.
    local legacy
    legacy="$(sched_find_ours | awk '$2 == "stale" { print $1 }' | head -n1)"
    if [ -z "${legacy}" ]; then
        legacy="$(sched_find_task_id "${SCHED_LEGACY_NAME}")"
    fi
    if [ -n "${legacy}" ]; then
        if /usr/syno/bin/synoschedtask --del "id=${legacy}" >/dev/null 2>&1; then
            log_info "Removed task ${legacy}, which ran the old syno-letsencrypt command."
        else
            log_warn "Could not remove task ${legacy}; delete it in Control Panel"
            log_warn "> Task Scheduler or renewal will run twice, failing once."
        fi
        sched_list_invalidate
    fi

    # Find ours by command rather than by name, and collapse any duplicates.
    # The stderr bug above caused a successful create to be read as a failure,
    # so the loop fell through to the second API and created a second task --
    # two renewals a night. Re-running the installer now heals that instead of
    # requiring the user to know it happened.
    local dupe
    existing=""
    for dupe in $(sched_find_ours | awk '$2 == "current" { print $1 }'); do
        if [ -z "${existing}" ]; then
            existing="${dupe}"
            continue
        fi
        if /usr/syno/bin/synoschedtask --del "id=${dupe}" >/dev/null 2>&1; then
            log_info "Removed duplicate renewal task ${dupe}."
        else
            log_warn "Duplicate renewal task ${dupe} could not be removed;"
            log_warn "delete it in Control Panel > Task Scheduler."
        fi
        sched_list_invalidate
    done
    [ -n "${existing}" ] || existing="$(sched_find_task_id)"

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

        # 2>/dev/null and strip to the first '{'. Capturing with 2>&1 merges
        # synowebapi's "[Line 295] Exec WebAPI: ..." progress line into the
        # JSON, jq cannot parse the result, and a call that SUCCEEDED is read
        # as a failure -- whereupon the loop tries the next API and creates a
        # second task. Measured: the installer reported it could not create
        # the entry, having created it.
        #
        # dsm.sh documents this trap and wraps it in syno_api. This file did
        # not use it.
        out="$(/usr/syno/bin/synowebapi "${args[@]}" 2>/dev/null | sed -n '/^[[:space:]]*{/,$p')"
        if printf '%s' "${out}" | jq -e '.success == true' >/dev/null 2>&1; then
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
    local id name
    for name in "${SCHED_TASK_NAME}" "${SCHED_LEGACY_NAME}"; do
        id="$(sched_find_task_id "${name}")"
        [ -n "${id}" ] || continue
        if /usr/syno/bin/synoschedtask --del "id=${id}" >/dev/null 2>&1; then
            log_info "Removed Task Scheduler entry ${id} (${name})."
        else
            log_warn "Could not remove task ${id}. Delete '${name}' in Control Panel > Task Scheduler."
        fi
    done
}

# sched_status — one line for `zenix-cert status`.
#
# Three distinct ways renewal can fail to happen, and they need different
# advice, so they are reported separately rather than collapsed into one "no":
# no task, a task calling the pre-rename command, and a task that exists but
# is disabled. The last two both look fine in Control Panel.
sched_status() {
    local found current stale enabled
    found="$(sched_find_ours)"
    current="$(printf '%s\n' "${found}" | awk '$2 == "current" { print $1 }' | head -n1)"
    stale="$(printf   '%s\n' "${found}" | awk '$2 == "stale"   { print $1 }' | head -n1)"

    if [ -z "${current}" ]; then
        if [ -n "${stale}" ]; then
            printf 'Scheduled:    NO — task %s still runs the old syno-letsencrypt\n' "${stale}"
            printf '              command, which no longer exists. Re-run install.sh.\n'
        else
            printf 'Scheduled:    NO — renewal will not run. Re-run install.sh.\n'
        fi
        return 1
    fi

    # A disabled task is not a scheduled task, however healthy it looks.
    enabled="$(sched_list_json | jq -r --arg i "${current}" \
                 '.data.tasks[]? | select((.id|tostring) == $i) | .enable' 2>/dev/null)"
    if [ "${enabled}" = "false" ]; then
        printf 'Scheduled:    NO — task %s exists but is DISABLED.\n' "${current}"
        printf '              Enable it in Control Panel > Task Scheduler.\n'
        return 1
    fi

    printf 'Scheduled:    yes (Task Scheduler id %s)\n' "${current}"
    local dupes
    dupes="$(printf '%s\n' "${found}" | awk '$2 == "current"' | wc -l | tr -d ' ')"
    if [ "${dupes}" -gt 1 ]; then
        printf '              warning: %s tasks run this command — renewal runs\n' "${dupes}"
        printf '              %s times a night. Re-run install.sh to collapse them.\n' "${dupes}"
    fi
    if [ -n "${stale}" ]; then
        printf '              warning: task %s also runs the old command — delete it,\n' "${stale}"
        printf '              or renewal is attempted twice and fails once.\n'
    fi
    /usr/syno/bin/synoschedtask --get "id=${current}" 2>/dev/null \
        | sed -n 's/^[[:space:]]*\(Last work time\|State\|Status\).*/              &/p' 2>/dev/null || true
    return 0
}
