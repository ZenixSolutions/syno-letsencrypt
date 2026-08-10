#!/bin/sh
# Follow-up probe. Answers two questions left open by the first one, then
# cleans up after both.
#
#   curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/tools/probe-task-scheduler-2.sh | sudo sh
#
# Deletes every task named "Zenix scheduler probe*" at the end.

WEBAPI=/usr/syno/bin/synowebapi

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }

echo "===================================================================="
echo "A. Full field list for one task (so we know how to find ours later)"
echo "===================================================================="
synoschedtask --get 2>&1 | grep -B4 -A8 "Zenix scheduler probe" | head -40
echo

echo "===================================================================="
echo "B. Raw output of the list API — what shape is it really?"
echo "===================================================================="
echo "--- version 3 ---"
$WEBAPI --exec-fastwebapi api=SYNO.Core.TaskScheduler method=list version=3 \
    offset=0 limit=5 2>&1 | head -60
echo
echo "--- version 1 ---"
$WEBAPI --exec-fastwebapi api=SYNO.Core.TaskScheduler method=list version=1 2>&1 | head -40
echo

echo "===================================================================="
echo "C. Do JSON-quoted string arguments silence the warnings?"
echo "===================================================================="
# synowebapi parses each value as JSON, so a bare string is 'not a json value'.
# Wrapping it in literal double quotes should make it a proper JSON string.
$WEBAPI --exec-fastwebapi \
  api=SYNO.Core.TaskScheduler.Root \
  method=create \
  version=4 \
  name='"Zenix scheduler probe 3"' \
  real_owner='"root"' \
  owner='"root"' \
  enable=true \
  type='"script"' \
  schedule='{"date_type":0,"monthly_week":"[]","hour":3,"minute":30,"repeat_hour":0,"repeat_min":0,"last_work_hour":3,"week_day":"0,1,2,3,4,5,6","repeat_date":1001}' \
  extra='{"notify_enable":false,"notify_mail":"","notify_if_error":false,"script":"/bin/true"}' 2>&1 | head -20
echo
echo "(If no 'Not a json value' lines appeared above, quoting is the fix.)"
echo

echo "===================================================================="
echo "D. Cleaning up every probe task"
echo "===================================================================="
# Pull ids straight from synoschedtask's text output, since that is the
# lookup that demonstrably works.
ids=$(synoschedtask --get 2>/dev/null \
      | awk '
          /\[Zenix scheduler probe/ { found=1 }
          /^[[:space:]]*(ID|Id|id)[[:space:]]*:/ { last=$0 }
          found && /^[[:space:]]*(ID|Id|id)[[:space:]]*:/ { print; found=0 }
        ' | tr -dc '0-9\n')

if [ -z "${ids}" ]; then
    echo "Could not read ids automatically. Full task list follows —"
    echo "delete them with: sudo synoschedtask --del id=<n>"
    synoschedtask --get 2>&1 | grep -B6 "Zenix" | head -40
else
    for id in ${ids}; do
        printf 'deleting id=%s ... ' "${id}"
        if synoschedtask --del "id=${id}" >/dev/null 2>&1; then
            echo "ok"
        else
            echo "FAILED"
        fi
    done
fi
echo
echo "Remaining probe tasks (should be none):"
synoschedtask --get 2>&1 | grep -c "Zenix scheduler probe" || true
echo
echo "If any survive, delete them in Control Panel > Task Scheduler."
