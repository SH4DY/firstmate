#!/usr/bin/env bash
# fm-bare-metal.sh - bring a cloudified task's execution back to its local worker.
#
# Usage:
#   fm-bare-metal.sh <task-id> [--cancel-active] [--dry-run]
#   fm-bare-metal.sh --all [--cancel-active] [--dry-run]
#   fm-bare-metal.sh -h | --help
#
# The reverse of bin/fm-cloudify.sh. The task never lost its window, so there is
# nothing to recreate: the worker in it stops being a waiter and resumes.
#
# Sequence per task:
#   1. Refuse unless location=cloud.
#   2. Refuse while a run is active. --cancel-active is the explicit instruction
#      to stop it first; without that flag this never silently interrupts work.
#   3. Capture the cloud agent's final result to data/<id>/handoff-return.md.
#      That text is the only record of the cloud agent's reasoning, so it is
#      captured BEFORE anything is archived or removed.
#   4. Fetch and fast-forward the worktree to the branch head. Refuse on
#      divergence rather than forcing: the cloud agent's commits are real work.
#   5. Archive the cloud agent (reversible; never DELETE), disarm the poll, and
#      set location=local while RETAINING cursor_agent for provenance.
#
# Options:
#   --cancel-active  cancel a still-running cloud run instead of refusing
#   --dry-run        report what would happen, change nothing
#
# Exit status:
#   0  every selected task returned
#   2  usage error
#   3  a required tool or configuration is missing
#   4  a task was refused, or an API or git step failed
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-cloudify-lib.sh
. "$SCRIPT_DIR/fm-cloudify-lib.sh"

CURSOR="$SCRIPT_DIR/fm-cursor.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {  # <code> <message...>
  local code=$1
  shift
  printf 'fm-bare-metal: %s\n' "$*" >&2
  exit "$code"
}

TARGET=''
ALL=0
CANCEL=0
DRY=0
while [ "$#" -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --all) ALL=1 ;;
    --cancel-active) CANCEL=1 ;;
    --dry-run) DRY=1 ;;
    -*) die 2 "unknown option: $1" ;;
    *) [ -z "$TARGET" ] || die 2 "pass one task id, or --all"; TARGET=$1 ;;
  esac
  shift
done
[ -z "$TARGET" ] || [ "$ALL" -eq 0 ] || die 2 "pass one task id, or --all, not both"
[ -n "$TARGET" ] || [ "$ALL" -eq 1 ] || die 2 "needs a task id, or --all"
[ -x "$CURSOR" ] || die 3 "bin/fm-cursor.sh is not available"

bare_metal_one() {  # <id>
  local id=$1 meta agent wt branch runs status result upstream behind ahead
  meta="$STATE/$id.meta"

  if [ ! -f "$meta" ]; then
    printf 'REFUSED %s: no such task in this home\n' "$id"
    return 1
  fi
  if [ "$(fm_cloudify_location "$meta")" != cloud ]; then
    printf 'REFUSED %s: location is not cloud, so there is nothing to bring back\n' "$id"
    return 1
  fi
  agent=$(fm_meta_get "$meta" cursor_agent)
  if [ -z "$agent" ]; then
    printf 'REFUSED %s: location=cloud but no cursor_agent is recorded\n' "$id"
    return 1
  fi

  if ! runs=$(FM_HOME="$FM_HOME" "$CURSOR" runs "$agent" --limit 1 --json 2>&1); then
    printf 'REFUSED %s: could not read cloud agent %s: %s\n' "$id" "$agent" "$(printf '%s' "$runs" | tail -1)"
    return 1
  fi
  status=$(printf '%s' "$runs" | jq -r '.runs[0].status // "none"')

  case $status in
    CREATING|RUNNING)
      if [ "$CANCEL" -eq 0 ]; then
        printf 'REFUSED %s: cloud run is %s; pass --cancel-active to stop it, or wait for it to finish\n' \
          "$id" "$status"
        return 1
      fi
      if [ "$DRY" -eq 1 ]; then
        printf 'would cancel the active run on %s, then return %s\n' "$agent" "$id"
      else
        FM_HOME="$FM_HOME" "$CURSOR" cancel "$agent" >/dev/null 2>&1 || true
        # Re-read: cancel is not instantaneous, and the result we capture below
        # should reflect the run's final state.
        runs=$(FM_HOME="$FM_HOME" "$CURSOR" runs "$agent" --limit 1 --json 2>/dev/null || printf '{}')
      fi
      ;;
  esac

  wt=$(fm_meta_get "$meta" worktree)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'REFUSED %s: no usable worktree (%s)\n' "$id" "${wt:-none recorded}"
    return 1
  fi
  # The branch comes from the WORKTREE, never from the API. Cursor reports
  # run.git.branches[].branch as `main` even when the commit landed on the
  # feature branch - verified live on 2026-08-01 - so trusting it here would
  # fast-forward the wrong branch. Do not "simplify" this back to the API value.
  branch=$(fm_cloudify_branch "$wt")
  if [ -z "$branch" ]; then
    printf 'REFUSED %s: worktree %s is on a detached HEAD, so there is no branch to fast-forward\n' "$id" "$wt"
    return 1
  fi

  if [ "$DRY" -eq 1 ]; then
    printf 'would return %s: fast-forward %s in %s, archive %s\n' "$id" "$branch" "$wt" "$agent"
    return 0
  fi

  # Capture the return handoff FIRST. It is the only record of the cloud agent's
  # reasoning, and every later step can fail.
  result=$(printf '%s' "$runs" | jq -r '.runs[0].result // empty')
  mkdir -p "$DATA/$id" 2>/dev/null || true
  {
    printf '# Return handoff - cloud agent %s\n\n' "$agent"
    printf 'Task %s, branch %s, final run status %s.\n\n' "$id" "$branch" "$status"
    if [ -n "$result" ]; then
      printf 'The cloud agent reported:\n\n'
      printf '%s\n' "$result"
    else
      printf 'The cloud agent reported no final text for its last run.\n'
    fi
  } > "$DATA/$id/handoff-return.md"

  # Fast-forward only. A divergence means the cloud agent and the local worktree
  # both moved, and the cloud agent's commits are real work - refuse rather than
  # reset, exactly as teardown refuses rather than discarding unlanded work.
  if ! git -C "$wt" fetch --quiet origin 2>/dev/null; then
    printf 'REFUSED %s: git fetch failed in %s; the return handoff is saved, nothing was archived\n' "$id" "$wt"
    return 1
  fi
  upstream=$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
  if [ -z "$upstream" ]; then
    printf 'REFUSED %s: branch %s has no upstream to fast-forward from\n' "$id" "$branch"
    return 1
  fi
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    printf 'REFUSED %s: worktree %s has local changes; resolve them before returning\n' "$id" "$wt"
    return 1
  fi
  ahead=$(git -C "$wt" rev-list --count "$upstream..HEAD" 2>/dev/null || echo unknown)
  behind=$(git -C "$wt" rev-list --count "HEAD..$upstream" 2>/dev/null || echo unknown)
  if [ "$ahead" = unknown ] || [ "$behind" = unknown ]; then
    printf 'REFUSED %s: cannot compare %s with %s; refusing rather than guessing\n' "$id" "$branch" "$upstream"
    return 1
  fi
  if [ "$ahead" != 0 ]; then
    printf 'REFUSED %s: %s is %s commit(s) ahead of %s and %s behind; that is a divergence, not a fast-forward. The cloud agent commits are real work - reconcile by hand\n' \
      "$id" "$branch" "$ahead" "$upstream" "$behind"
    return 1
  fi
  if [ "$behind" != 0 ]; then
    if ! git -C "$wt" merge --ff-only "$upstream" >/dev/null 2>&1; then
      printf 'REFUSED %s: fast-forward of %s onto %s failed\n' "$id" "$branch" "$upstream"
      return 1
    fi
  fi

  # Archive is reversible and is the only cleanup verb; DELETE is never wired.
  if ! FM_HOME="$FM_HOME" "$CURSOR" archive "$agent" >/dev/null 2>&1; then
    printf 'WARNING %s: returned locally, but archiving cloud agent %s failed; archive it by hand\n' "$id" "$agent" >&2
  fi

  rm -f -- "$STATE/$id.check.sh" "$STATE/$id.check-trust" "$STATE/$id.cursor-reported" 2>/dev/null || true
  # cursor_agent is deliberately RETAINED: it is the provenance of who did this
  # work, and the agent is archived rather than gone.
  fm_cloudify_meta_set "$meta" location local || die 4 "could not record location for $id"

  printf 'returned %s: %s is at %s, cloud agent %s archived\n' \
    "$id" "$branch" "$(git -C "$wt" rev-parse --short HEAD)" "$agent"
  printf '  return handoff: data/%s/handoff-return.md\n' "$id"
  return 0
}

RC=0
if [ "$ALL" -eq 1 ]; then
  found=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(fm_cloudify_location "$STATE/$id.meta")" = cloud ] || continue
    found=1
    bare_metal_one "$id" || RC=4
  done <<EOF
$(fm_cloudify_task_ids "$STATE")
EOF
  [ "$found" -eq 1 ] || echo 'no cloudified tasks to return'
else
  bare_metal_one "$TARGET" || RC=4
fi
exit "$RC"
