#!/usr/bin/env bash
# Validate or remove a task's private PR remediation markers and CI repair count.
# Usage: fm-pr-remediation-cleanup.sh <validate|remove> <state-directory> <task-id>
# Teardown invokes this bounded subprocess instead of importing remediation into
# its recursive source graph. Both modes validate every artifact before removal;
# an already-removed remote home is a no-op, but dangling state links refuse.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-remediation-lib.sh
. "$SCRIPT_DIR/fm-pr-remediation-lib.sh"

[ "$#" -eq 3 ] || { echo 'error: expected action, state directory and task id' >&2; exit 2; }
ACTION=$1
STATE=$2
ID=$3
case "$ACTION" in validate|remove) ;; *) echo 'error: invalid remediation cleanup action' >&2; exit 2 ;; esac
fm_pr_task_id_valid "$ID" || exit 2
if [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; then
  exit 0
fi
[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  echo 'REFUSED: unsafe remediation state directory; preserving task state.' >&2
  exit 1
}
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
if [ -e "$STATE/$ID.pr-ci-fix-count" ] || [ -L "$STATE/$ID.pr-ci-fix-count" ]; then
  fm_pr_ci_fix_count_file_valid "$STATE/$ID.pr-ci-fix-count" "$STATE_DEVICE" || {
    echo 'REFUSED: invalid CI fix count; preserving task state.' >&2
    exit 1
  }
fi
fm_pr_poll_event_markers_valid "$STATE" "$ID" || {
  echo 'REFUSED: unsafe PR-poll event marker; preserving task state.' >&2
  exit 1
}
if [ "$ACTION" = remove ]; then
  fm_pr_poll_event_markers_remove "$STATE" "$ID"
  fm_pr_ci_fix_count_remove "$STATE" "$ID"
fi
