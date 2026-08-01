#!/usr/bin/env bash
# fm-cloudify.sh - move a task's execution from its local worker to a Cursor
# Cloud agent, keeping the task's identity, meta, status file and window.
#
# Usage:
#   fm-cloudify.sh <task-id> [--env <name>] [--model <id>] [--dry-run]
#   fm-cloudify.sh --all [--env <name>] [--model <id>] [--dry-run]
#   fm-cloudify.sh -h | --help
#
# Only WHERE the work executes moves. The task keeps its window, and the worker
# in it becomes a waiter exactly as it already is while a no-mistakes run's
# separate agent process does the work. Nothing becomes windowless, so session
# start, bin/fm-crew-state.sh and stuck-crewmate-recovery need no exemption.
#
# What this script owns is the deterministic part: preflight, creating the agent,
# recording the link, and arming the poll. What it deliberately does NOT own is
# the judgment: instructing the worker to commit, push and write its handoff, and
# waiting for that to finish, belongs to firstmate and the
# `firstmate-cursor-cloud` skill. This script REQUIRES data/<id>/handoff.md to
# already exist, which turns "the worker wrote its handoff first" into an
# enforced precondition rather than a hoped-for one.
#
# Preflight refuses per task, naming the exact failing condition, and never
# partially migrates. Rules on uncommitted and unpushed work are hard rule 3
# territory: cloudifying either destroys it, so there is no --force.
#
# --all applies to every eligible local task and reports each refusal
# individually; one task failing preflight never blocks the others. The exit
# status is non-zero if ANY task was refused, so a caller cannot mistake a
# partial sweep for a clean one.
#
# Options:
#   --env <name>   environment for the cloud agent; defaults to this home's
#                  config/cursor-environment, which is the whole point of that file
#   --model <id>   model for the cloud agent, validated by bin/fm-cursor.sh
#   --dry-run      run preflight and print what would happen, create nothing
#
# Environment:
#   FM_HOME        home whose state/, data/ and config/ are used
#
# Exit status:
#   0  every selected task was cloudified (or would be, under --dry-run)
#   2  usage error
#   3  a required tool or configuration is missing
#   4  a task was refused by preflight, or an API call failed
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
  printf 'fm-cloudify: %s\n' "$*" >&2
  exit "$code"
}

TARGET=''
ALL=0
ENV_NAME=''
MODEL=''
DRY=0
while [ "$#" -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --all) ALL=1 ;;
    --dry-run) DRY=1 ;;
    --env) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--env needs a name"; ENV_NAME=$2; shift ;;
    --env=*) ENV_NAME=${1#--env=} ;;
    --model) [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--model needs an id"; MODEL=$2; shift ;;
    --model=*) MODEL=${1#--model=} ;;
    -*) die 2 "unknown option: $1" ;;
    *) [ -z "$TARGET" ] || die 2 "pass one task id, or --all"; TARGET=$1 ;;
  esac
  shift
done
[ -z "$TARGET" ] || [ "$ALL" -eq 0 ] || die 2 "pass one task id, or --all, not both"
[ -n "$TARGET" ] || [ "$ALL" -eq 1 ] || die 2 "needs a task id, or --all"
[ -x "$CURSOR" ] || die 3 "bin/fm-cursor.sh is not available"

# One task. Echoes progress; returns non-zero when refused.
cloudify_one() {  # <id>
  local id=$1 meta wt branch reason handoff prompt_file created agent_id agent_url
  meta="$STATE/$id.meta"

  if ! reason=$(fm_cloudify_preflight "$STATE" "$id"); then
    printf 'REFUSED %s: %s\n' "$id" "$reason"
    return 1
  fi

  wt=$(fm_meta_get "$meta" worktree)
  branch=$(fm_cloudify_branch "$wt")
  handoff="$DATA/$id/handoff.md"
  if [ ! -s "$handoff" ]; then
    printf 'REFUSED %s: no handoff at data/%s/handoff.md; the worker must commit, push and write its handoff before this runs\n' \
      "$id" "$id"
    return 1
  fi

  if [ "$DRY" -eq 1 ]; then
    printf 'would cloudify %s: branch %s, handoff %s bytes, env %s\n' \
      "$id" "$branch" "$(wc -c < "$handoff" | tr -d ' ')" "${ENV_NAME:-<config/cursor-environment>}"
    return 0
  fi

  # The prompt is the worker's handoff plus the instruction that puts the agent
  # on the existing branch. Naming an environment and controlling the branch are
  # NOT an either/or choice: `repos` is mutually exclusive with a named
  # environment, but workOnCurrentBranch plus a checkout instruction reaches the
  # same place while keeping the environment's secrets and MCP configuration.
  # Verified live on 2026-08-01.
  prompt_file=$(mktemp "${TMPDIR:-/tmp}/.fm-cloudify-prompt.XXXXXX") || die 3 "could not create a prompt file"
  trap 'rm -f -- "$prompt_file"' EXIT HUP INT TERM
  {
    printf 'You are taking over an in-progress task from a local worker.\n\n'
    printf 'FIRST, put yourself on the right branch. In the checkout of the repository this task\n'
    printf 'belongs to, run:\n\n'
    printf '    git fetch origin\n'
    printf '    git checkout %s\n\n' "$branch"
    printf 'Commit your work to that branch and push it there. Do NOT create a new branch, do not\n'
    printf 'open a pull request unless the handoff asks for one, and do not touch the default branch.\n\n'
    printf 'The handoff below is the previous worker every bit of context that is not in git.\n'
    printf 'Read it before doing anything: it records what was tried and rejected, what looks wrong\n'
    printf 'but is deliberate, and how to verify the work.\n\n'
    printf -- '--- HANDOFF ---\n\n'
    cat "$handoff"
  } > "$prompt_file"

  local create_args
  create_args=(create --json --work-on-current-branch --prompt-file "$prompt_file")
  [ -z "$ENV_NAME" ] || create_args+=(--env "$ENV_NAME")
  [ -z "$MODEL" ] || create_args+=(--model "$MODEL")

  if ! created=$(FM_HOME="$FM_HOME" "$CURSOR" "${create_args[@]}" 2>&1); then
    printf 'REFUSED %s: creating the cloud agent failed: %s\n' "$id" "$(printf '%s' "$created" | tail -1)"
    rm -f -- "$prompt_file"
    trap - EXIT HUP INT TERM
    return 1
  fi
  rm -f -- "$prompt_file"
  trap - EXIT HUP INT TERM

  agent_id=$(printf '%s' "$created" | jq -r '(.agent.id // .id) // empty')
  agent_url=$(printf '%s' "$created" | jq -r '(.agent.url // .url) // empty')
  if [ -z "$agent_id" ]; then
    printf 'REFUSED %s: the create response carried no agent id\n' "$id"
    return 1
  fi

  fm_cloudify_meta_set "$meta" cursor_agent "$agent_id" || die 4 "could not record cursor_agent for $id"
  fm_cloudify_meta_set "$meta" location cloud || die 4 "could not record location for $id"

  # Arm the poll through the existing check seam, so a cloud run transition
  # arrives as an ordinary `check:` wake. Deliberately NOT a second watcher.
  if ! "$SCRIPT_DIR/fm-cloudify-arm-check.sh" "$id" "$agent_id"; then
    printf 'WARNING %s: cloudified, but arming the poll failed; supervise it manually\n' "$id" >&2
  fi

  printf 'cloudified %s: branch %s now runs on cloud agent %s\n' "$id" "$branch" "$agent_id"
  [ -z "$agent_url" ] || printf '  %s\n' "$agent_url"
  return 0
}

RC=0
if [ "$ALL" -eq 1 ]; then
  found=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # --all means every eligible LOCAL task; a task already in the cloud is not a
    # refusal worth reporting, it is simply not selected.
    [ "$(fm_cloudify_location "$STATE/$id.meta")" = local ] || continue
    found=1
    cloudify_one "$id" || RC=4
  done <<EOF
$(fm_cloudify_task_ids "$STATE")
EOF
  [ "$found" -eq 1 ] || echo 'no local tasks to cloudify'
else
  cloudify_one "$TARGET" || RC=4
fi
exit "$RC"
