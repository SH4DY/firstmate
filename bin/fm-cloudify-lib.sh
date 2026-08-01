#!/usr/bin/env bash
# fm-cloudify-lib.sh - shared mechanics for moving one task between a local
# worker and a Cursor Cloud agent.
#
# This file is sourced, never executed. bin/fm-cloudify.sh and
# bin/fm-bare-metal.sh own the two directions; this owns what both need: the
# location field, the durable agent link, and the preflight that decides whether
# a task may move at all.
#
# The model, which is what makes the rest simple: a task keeps its identity, its
# `state/<id>.meta`, its status file AND its runtime window in BOTH modes. Only
# where the work executes moves. The pane idles as a waiter exactly as it already
# does while a no-mistakes run's separate agent process does the work, so there
# are no windowless tasks, and session start, bin/fm-crew-state.sh and
# stuck-crewmate-recovery need no exemption for a cloudified task.
#
# Meta fields this owns:
#   location=local|cloud   absent means local
#   cursor_agent=bc-...    set while cloudified, RETAINED after returning so the
#                          cloud agent that did the work stays discoverable

# fm_cloudify_location <meta-file> -> local|cloud
fm_cloudify_location() {
  local v
  v=$(fm_meta_get "$1" location)
  printf '%s' "${v:-local}"
}

# Replace or append one key in a meta file, atomically, preserving every other
# line and its order. Never rewrites a meta from a template: a task's meta
# carries backend-specific fields this code has no business reconstructing.
fm_cloudify_meta_set() {  # <meta-file> <key> <value>
  local meta=$1 key=$2 value=$3 tmp
  [ -f "$meta" ] || return 1
  tmp=$(mktemp "${meta%/*}/.fm-cloudify-meta.XXXXXX") || return 1
  if grep -q "^$key=" "$meta" 2>/dev/null; then
    awk -v k="$key" -v v="$value" -F= '
      $1 == k && !done { print k "=" v; done = 1; next }
      { print }
    ' "$meta" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  else
    cat "$meta" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$meta" || { rm -f -- "$tmp"; return 1; }
}

# Remove one key entirely.
fm_cloudify_meta_unset() {  # <meta-file> <key>
  local meta=$1 key=$2 tmp
  [ -f "$meta" ] || return 1
  grep -q "^$key=" "$meta" 2>/dev/null || return 0
  tmp=$(mktemp "${meta%/*}/.fm-cloudify-meta.XXXXXX") || return 1
  grep -v "^$key=" "$meta" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$meta" || { rm -f -- "$tmp"; return 1; }
}

# Every local task recorded in this home, one id per line.
fm_cloudify_task_ids() {  # <state-dir>
  local state=$1 meta id
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    printf '%s\n' "$id"
  done
}

# fm_cloudify_remote_ref <worktree> <branch>
#
# The remote ref this branch should be compared against, printed on stdout.
#
# A configured upstream is preferred, but its ABSENCE does not mean the branch is
# unpublished. `git push <remote> <branch>` without -u pushes the branch and
# updates refs/remotes/<remote>/<branch> while setting no tracking config at all,
# which is an extremely common state - and treating it as "no upstream" is a
# false negative that refuses a branch which is demonstrably on its remote.
#
# Strictly read-only: this never sets an upstream, never writes git config, and
# never fetches. Preflight must not change the operator's repository to make its
# own check pass.
#
# Exit status:
#   0  a locally-resolvable ref was found and printed
#   2  the branch exists on a remote but has not been fetched here, so nothing
#      local can be compared against it yet
#   1  the branch is on no remote at all - the genuine refusal
fm_cloudify_remote_ref() {  # <worktree> <branch>
  local wt=$1 branch=$2 ref remote remotes
  ref=$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s' "$ref"
    return 0
  fi

  # origin first, then any other remote, so the common case resolves predictably.
  remotes=$(git -C "$wt" remote 2>/dev/null || true)
  for remote in origin $remotes; do
    [ -n "$remote" ] || continue
    if git -C "$wt" rev-parse --verify --quiet "refs/remotes/$remote/$branch" >/dev/null 2>&1; then
      printf '%s/%s' "$remote" "$branch"
      return 0
    fi
  done

  # Nothing fetched locally. Ask the remotes themselves before refusing, so a
  # branch that is published but not mirrored here is reported as needing a
  # fetch rather than as unpublished.
  for remote in origin $remotes; do
    [ -n "$remote" ] || continue
    if git -C "$wt" ls-remote --exit-code --heads "$remote" "$branch" >/dev/null 2>&1; then
      return 2
    fi
  done
  return 1
}

# fm_cloudify_preflight <state-dir> <id>
#
# The six conditions from the design, in order, each refusing with the exact
# failing condition rather than a generic error. Echoes the reason and returns
# non-zero on the first failure; silent and zero when the task may move.
#
# Rules 4 and 5 are hard rule 3 territory. Cloudifying a worktree that holds
# uncommitted or unpushed work destroys it, because the cloud agent starts from
# what the remote has and the local worktree is later fast-forwarded onto its
# result. There is deliberately no --force: the correct fix is for the worker to
# commit and push, which the caller asks it to do before this runs.
fm_cloudify_preflight() {  # <state-dir> <id>
  local state=$1 id=$2 meta wt branch upstream ahead
  meta="$state/$id.meta"

  if [ ! -f "$meta" ]; then
    printf 'no such task: %s has no state/%s.meta in this home' "$id" "$id"
    return 1
  fi

  local loc
  loc=$(fm_cloudify_location "$meta")
  if [ "$loc" != local ]; then
    printf 'task %s is already location=%s' "$id" "$loc"
    return 1
  fi

  # A live window is required because the window is what the task keeps in both
  # modes; without one there is nothing to hand back to on return.
  local window backend
  window=$(fm_meta_get "$meta" window)
  if [ -z "$window" ]; then
    printf 'task %s has no window recorded, so there is no worker to hand back to' "$id"
    return 1
  fi
  backend=$(fm_backend_of_meta "$meta")
  if ! fm_backend_target_exists "$backend" \
      "$(fm_backend_target_of_meta "$meta")" "fm-$id" 2>/dev/null; then
    printf 'task %s has no live window (%s target %s is gone)' "$id" "$backend" "$window"
    return 1
  fi

  wt=$(fm_meta_get "$meta" worktree)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'task %s has no usable worktree (%s)' "$id" "${wt:-none recorded}"
    return 1
  fi

  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$branch" ]; then
    printf 'task %s is on a detached HEAD in %s, so there is no branch for the cloud agent to check out' "$id" "$wt"
    return 1
  fi

  local rr_rc=0
  upstream=$(fm_cloudify_remote_ref "$wt" "$branch") || rr_rc=$?
  if [ "$rr_rc" -eq 2 ]; then
    printf 'task %s branch %s is on its remote but has not been fetched into %s; run git fetch there so the preflight can verify nothing is unpushed' \
      "$id" "$branch" "$wt"
    return 1
  fi
  if [ "$rr_rc" -ne 0 ] || [ -z "$upstream" ]; then
    printf 'task %s branch %s has no upstream remote, so the cloud agent cannot fetch it' "$id" "$branch"
    return 1
  fi

  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    printf 'task %s has uncommitted changes in %s; commit and push before cloudifying or they are lost' "$id" "$wt"
    return 1
  fi

  ahead=$(git -C "$wt" rev-list --count "$upstream..HEAD" 2>/dev/null || echo unknown)
  if [ "$ahead" = unknown ]; then
    printf 'task %s cannot be compared with %s; refusing rather than guessing what is pushed' "$id" "$upstream"
    return 1
  fi
  if [ "$ahead" != 0 ]; then
    printf 'task %s is %s commit(s) ahead of %s; push before cloudifying or that work is lost' "$id" "$ahead" "$upstream"
    return 1
  fi

  return 0
}

# The branch and upstream a cloudified task works on. Read from the WORKTREE,
# never from the API.
#
# The Cloud Agents API reports `run.git.branches[].branch` as `main` even when the
# commit demonstrably landed on the feature branch - verified live on 2026-08-01,
# where a probe committed to `cursor-probe/...` while the API reported `main` and
# `main` never moved. Deriving the return branch from that field would make
# /bare-metal fast-forward against the wrong branch. Firstmate already knows the
# branch; this is the only trustworthy source.
fm_cloudify_branch() {  # <worktree>
  git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}
