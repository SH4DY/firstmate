#!/usr/bin/env bash
# Read or claim a bounded automatic CI-fix cycle for one GitHub pull request.
# The private count is keyed by task and canonical PR URL, so re-arming that
# task for a different PR starts at zero without resetting the prior PR's limit.
# `claim` atomically records one cycle before the worker is steered and allows at
# most two cycles; it prints one line and exits 3 when the limit is exhausted.
# Usage: fm-pr-ci-fix-count.sh <get|claim> <task-id> <github-pr-url>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 3 ]; then
  echo "error: invalid CI fix count request" >&2
  exit 2
fi

ACTION=$1
ID=$2
URL=$3
case "$ACTION" in get|claim) ;; *) echo "error: invalid CI fix count request" >&2; exit 2 ;; esac

if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$URL" \
  || [ "$FM_PR_PROVIDER" != github ] || [ "$FM_PR_URL" != "$URL" ]; then
  echo "error: invalid CI fix count request" >&2
  exit 2
fi

case "$ACTION" in
  get)
    fm_pr_ci_fix_count_get "$STATE" "$ID" "$URL" || {
      echo "error: CI fix count is unavailable" >&2
      exit 1
    }
    printf '%s\n' "$FM_PR_CI_FIX_COUNT"
    ;;
  claim)
    rc=0
    fm_pr_ci_fix_count_claim "$STATE" "$ID" "$URL" || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf 'claimed: %s\n' "$FM_PR_CI_FIX_COUNT"
      exit 0
    fi
    case "$rc" in
      3) printf 'exhausted: 2\n'; exit 3 ;;
      *) echo "error: CI fix count is unavailable" >&2; exit 1 ;;
    esac
    ;;
esac
