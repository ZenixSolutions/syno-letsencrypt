#!/bin/sh
# Throwaway probe: can we create a DSM Task Scheduler entry from a root shell?
#
#   sudo sh sched-test.sh
#
# Creates one harmless task named "Zenix scheduler probe" that runs `/bin/true`
# daily at 03:30, then lists it back. Delete it afterwards with the command
# printed at the end, or from Control Panel -> Task Scheduler.
#
# Nothing else is touched.

WEBAPI=/usr/syno/bin/synowebapi
NAME="Zenix scheduler probe"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }

echo "===================================================================="
echo "1. Which TaskScheduler APIs exist, and at what versions?"
echo "===================================================================="
$WEBAPI --exec-fastwebapi api=SYNO.API.Info method=query version=1 \
    query=SYNO.Core.TaskScheduler,SYNO.Core.TaskScheduler.Root,SYNO.Core.EventScheduler 2>&1
echo

echo "===================================================================="
echo "2. Existing tasks (names and owners only)"
echo "===================================================================="
$WEBAPI --exec-fastwebapi api=SYNO.Core.TaskScheduler method=list version=3 \
    offset=0 limit=100 2>&1 \
  | jq -r '.data.tasks[]? | "  [\(.id)] \(.name)   owner=\(.real_owner // .owner)  type=\(.type)  enabled=\(.enable)"' \
  2>/dev/null || echo "  (could not parse - raw output above)"
echo

echo "===================================================================="
echo "3. Creating a test task as root"
echo "===================================================================="
echo "Trying SYNO.Core.TaskScheduler.Root ..."
$WEBAPI --exec-fastwebapi \
  api=SYNO.Core.TaskScheduler.Root \
  method=create \
  version=4 \
  name="${NAME}" \
  real_owner=root \
  owner=root \
  enable=true \
  type=script \
  schedule='{"date_type":0,"monthly_week":"[]","hour":3,"minute":30,"repeat_hour":0,"repeat_min":0,"last_work_hour":3,"week_day":"0,1,2,3,4,5,6","repeat_date":1001}' \
  extra='{"notify_enable":false,"notify_mail":"","notify_if_error":false,"script":"/bin/true"}' 2>&1
echo

echo "If that failed, trying the non-.Root API ..."
$WEBAPI --exec-fastwebapi \
  api=SYNO.Core.TaskScheduler \
  method=create \
  version=4 \
  name="${NAME} 2" \
  real_owner=root \
  owner=root \
  enable=true \
  type=script \
  schedule='{"date_type":0,"monthly_week":"[]","hour":3,"minute":30,"repeat_hour":0,"repeat_min":0,"last_work_hour":3,"week_day":"0,1,2,3,4,5,6","repeat_date":1001}' \
  extra='{"notify_enable":false,"notify_mail":"","notify_if_error":false,"script":"/bin/true"}' 2>&1
echo

echo "===================================================================="
echo "4. Did anything appear?"
echo "===================================================================="
synoschedtask --get 2>&1 | grep -iA3 "Zenix" || echo "  (nothing named Zenix found by synoschedtask)"
echo
echo "--- and via the API ---"
$WEBAPI --exec-fastwebapi api=SYNO.Core.TaskScheduler method=list version=3 \
    offset=0 limit=100 2>&1 \
  | jq -r '.data.tasks[]? | select(.name | test("Zenix")) | "  [\(.id)] \(.name)  owner=\(.real_owner // .owner)  enabled=\(.enable)"' \
  2>/dev/null || true
echo

echo "===================================================================="
echo "Now open Control Panel -> Task Scheduler and see if it is listed."
echo
echo "To remove it:   sudo synoschedtask --del id=<id from above>"
echo "===================================================================="
