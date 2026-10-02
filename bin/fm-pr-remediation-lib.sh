#!/usr/bin/env bash
# Nonterminal GitHub PR events and bounded CI repair counters.
# Source after bin/fm-pr-lib.sh. Only remediation and cleanup callers need
# these helpers; keep them out of the shared forge-record source graph.

# Poll events are non-terminal observations that must wake once per PR URL,
# head, and condition. A marker is private state, not poll identity, so it never
# participates in the static-source provenance proof.
FM_PR_POLL_EVENT_KIND=
FM_PR_POLL_EVENT_HEAD=
FM_PR_POLL_EVENT_FINGERPRINT=
FM_PR_POLL_EVENT_MARKER_URL=
FM_PR_POLL_EVENT_MARKER_HEAD=
FM_PR_CI_FIX_COUNT_URL=
FM_PR_CI_FIX_COUNT=0

fm_pr_poll_event_kind_valid() {
  case "${1-}" in behind|ci) return 0 ;; *) return 1 ;; esac
}

fm_pr_poll_event_fingerprint_valid() {
  [[ "${1-}" =~ ^[0-9a-f]{64}$ ]]
}

fm_pr_poll_event_parse() {  # <poll output line>
  local line=$1 rest head fingerprint
  FM_PR_POLL_EVENT_KIND=
  FM_PR_POLL_EVENT_HEAD=
  FM_PR_POLL_EVENT_FINGERPRINT=
  case "$line" in
    behind\ *)
      rest=${line#behind }
      head=${rest%% *}
      [ "$rest" = "$head" ] || return 1
      fm_pr_head_valid "$head" || return 1
      FM_PR_POLL_EVENT_KIND=behind
      FM_PR_POLL_EVENT_HEAD=$head
      ;;
    ci-failed\ *)
      rest=${line#ci-failed }
      head=${rest%% *}
      rest=${rest#"$head"}
      rest=${rest#' '}
      fingerprint=${rest%% *}
      [ "$rest" = "$fingerprint" ] || return 1
      fm_pr_head_valid "$head" || return 1
      fm_pr_poll_event_fingerprint_valid "$fingerprint" || return 1
      # shellcheck disable=SC2034 # Read by bin/fm-watch.sh after parsing.
      FM_PR_POLL_EVENT_KIND=ci
      # shellcheck disable=SC2034 # Read by bin/fm-watch.sh after parsing.
      FM_PR_POLL_EVENT_HEAD=$head
      # shellcheck disable=SC2034 # Read by bin/fm-watch.sh after parsing.
      FM_PR_POLL_EVENT_FINGERPRINT=$fingerprint
      ;;
    *) return 1 ;;
  esac
}

fm_pr_poll_event_marker_path() {  # <state> <task-id> <behind|ci> [fingerprint]
  local state=$1 id=$2 kind=$3 fingerprint=${4:-}
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_poll_event_kind_valid "$kind" || return 1
  case "$kind" in
    behind)
      [ -z "$fingerprint" ] || return 1
      printf '%s/.pr-poll-event-%s-behind\n' "$state" "$id"
      ;;
    ci)
      fm_pr_poll_event_fingerprint_valid "$fingerprint" || return 1
      printf '%s/.pr-poll-event-%s-ci-%s\n' "$state" "$id" "$fingerprint"
      ;;
  esac
}

fm_pr_poll_event_marker_parse() {  # <private marker file>
  local file=$1 version url head _extra
  FM_PR_POLL_EVENT_MARKER_URL=
  FM_PR_POLL_EVENT_MARKER_HEAD=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 6< "$file" || return 1
  IFS= read -r version <&6 || { exec 6<&-; return 1; }
  IFS= read -r url <&6 || { exec 6<&-; return 1; }
  IFS= read -r head <&6 || { exec 6<&-; return 1; }
  if IFS= read -r _extra <&6; then
    exec 6<&-
    return 1
  fi
  exec 6<&-
  [ "$version" = fm-pr-poll-event-v1 ] || return 1
  fm_pr_url_parse "$url" || return 1
  fm_pr_head_valid "$head" || return 1
  FM_PR_POLL_EVENT_MARKER_URL=$FM_PR_URL
  FM_PR_POLL_EVENT_MARKER_HEAD=$head
}

fm_pr_poll_event_marker_file_valid() {  # <marker> <state-device>
  local marker=$1 state_device=$2
  fm_pr_private_file_valid "$marker" 600 "$state_device" || return 1
  fm_pr_poll_event_marker_parse "$marker"
}

fm_pr_poll_event_marker_name_valid() {  # <basename> <task-id>
  local basename=$1 id=$2 prefix fingerprint
  fm_pr_task_id_valid "$id" || return 1
  [ "$basename" = ".pr-poll-event-$id-behind" ] && return 0
  prefix=".pr-poll-event-$id-ci-"
  case "$basename" in "$prefix"*) ;; *) return 1 ;; esac
  fingerprint=${basename#"$prefix"}
  fm_pr_poll_event_fingerprint_valid "$fingerprint"
}

# Return 0 when the exact event was already surfaced, 1 when it is new, and 2
# when a private marker is malformed or unsafe.
fm_pr_poll_event_seen() {  # <state> <task-id> <kind> <url> <head> [fingerprint]
  local state=$1 id=$2 kind=$3 url=$4 head=$5 fingerprint=${6:-} marker state_device
  fm_pr_url_parse "$url" || return 2
  [ "$url" = "$FM_PR_URL" ] || return 2
  fm_pr_head_valid "$head" || return 2
  marker=$(fm_pr_poll_event_marker_path "$state" "$id" "$kind" "$fingerprint") || return 2
  [ -d "$state" ] && [ ! -L "$state" ] || return 2
  state_device=$(fm_pr_file_device "$state") || return 2
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  fm_pr_poll_event_marker_file_valid "$marker" "$state_device" || return 2
  [ "$FM_PR_POLL_EVENT_MARKER_URL" = "$url" ] \
    && [ "$FM_PR_POLL_EVENT_MARKER_HEAD" = "$head" ] && return 0
  return 1
}

fm_pr_poll_event_mark_seen() {  # <state> <task-id> <kind> <url> <head> [fingerprint]
  local state=$1 id=$2 kind=$3 url=$4 head=$5 fingerprint=${6:-} marker state_device tmp
  fm_pr_url_parse "$url" || return 1
  [ "$url" = "$FM_PR_URL" ] || return 1
  fm_pr_head_valid "$head" || return 1
  marker=$(fm_pr_poll_event_marker_path "$state" "$id" "$kind" "$fingerprint") || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    fm_pr_poll_event_marker_file_valid "$marker" "$state_device" || return 1
  fi
  fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-poll-event.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n' fm-pr-poll-event-v1 "$url" "$head" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_poll_event_marker_file_valid "$tmp" "$state_device" \
    || [ "$FM_PR_POLL_EVENT_MARKER_URL" != "$url" ] \
    || [ "$FM_PR_POLL_EVENT_MARKER_HEAD" != "$head" ] \
    || ! fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" \
    || ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_poll_event_marker_file_valid "$marker" "$state_device" \
    && [ "$FM_PR_POLL_EVENT_MARKER_URL" = "$url" ] \
    && [ "$FM_PR_POLL_EVENT_MARKER_HEAD" = "$head" ]
}

fm_pr_poll_event_markers_valid() {  # <state> <task-id>
  local state=$1 id=$2 state_device marker basename
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  for marker in "$state/.pr-poll-event-$id-behind" "$state/.pr-poll-event-$id-ci-"*; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    basename=${marker##*/}
    fm_pr_poll_event_marker_name_valid "$basename" "$id" || return 1
    fm_pr_poll_event_marker_file_valid "$marker" "$state_device" || return 1
  done
}

fm_pr_poll_event_markers_remove() {  # <state> <task-id>
  local state=$1 id=$2 state_device marker basename
  fm_pr_task_id_valid "$id" || return 1
  # Remote secondmate control records live inside the home just retired.
  # An absent directory has no markers left; a dangling symlink is not absence.
  if [ ! -e "$state" ] && [ ! -L "$state" ]; then
    return 0
  fi
  fm_pr_poll_event_markers_valid "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  for marker in "$state/.pr-poll-event-$id-behind" "$state/.pr-poll-event-$id-ci-"*; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    basename=${marker##*/}
    fm_pr_poll_event_marker_name_valid "$basename" "$id" || return 1
    fm_pr_poll_event_marker_file_valid "$marker" "$state_device" || return 1
    rm -f -- "$marker" || return 1
  done
}

fm_pr_ci_fix_count_path() {  # <state> <task-id>
  fm_pr_task_id_valid "$2" || return 1
  printf '%s/%s.pr-ci-fix-count\n' "$1" "$2"
}

fm_pr_ci_fix_count_parse() {  # <private count file>
  local file=$1 version url count _extra
  FM_PR_CI_FIX_COUNT_URL=
  FM_PR_CI_FIX_COUNT=0
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 6< "$file" || return 1
  IFS= read -r version <&6 || { exec 6<&-; return 1; }
  IFS= read -r url <&6 || { exec 6<&-; return 1; }
  IFS= read -r count <&6 || { exec 6<&-; return 1; }
  if IFS= read -r _extra <&6; then
    exec 6<&-
    return 1
  fi
  exec 6<&-
  [ "$version" = fm-pr-ci-fix-count-v1 ] || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_PROVIDER" = github ] || return 1
  case "$count" in 0|1|2) ;; *) return 1 ;; esac
  FM_PR_CI_FIX_COUNT_URL=$FM_PR_URL
  FM_PR_CI_FIX_COUNT=$count
}

fm_pr_ci_fix_count_file_valid() {  # <count file> <state-device>
  local file=$1 state_device=$2
  fm_pr_private_file_valid "$file" 600 "$state_device" || return 1
  fm_pr_ci_fix_count_parse "$file"
}

fm_pr_ci_fix_count_get() {  # <state> <task-id> <github-pr-url>
  local state=$1 id=$2 url=$3 file state_device
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_PROVIDER" = github ] && [ "$FM_PR_URL" = "$url" ] || return 1
  file=$(fm_pr_ci_fix_count_path "$state" "$id") || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    FM_PR_CI_FIX_COUNT=0
    return 0
  fi
  fm_pr_ci_fix_count_file_valid "$file" "$state_device" || return 1
  [ "$FM_PR_CI_FIX_COUNT_URL" = "$url" ] || FM_PR_CI_FIX_COUNT=0
}

# Return 0 after claiming one of two cycles, 3 when the PR exhausted both
# cycles, and 1 for unsafe or unreadable private state.
fm_pr_ci_fix_count_claim() {  # <state> <task-id> <github-pr-url>
  local state=$1 id=$2 url=$3 file state_device current next tmp
  fm_pr_ci_fix_count_get "$state" "$id" "$url" || return 1
  current=$FM_PR_CI_FIX_COUNT
  [ "$current" -lt 2 ] || return 3
  next=$((current + 1))
  file=$(fm_pr_ci_fix_count_path "$state" "$id") || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_regular_destination_on_device_or_absent "$file" "$state_device" || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-ci-fix-count.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n' fm-pr-ci-fix-count-v1 "$url" "$next" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_ci_fix_count_file_valid "$tmp" "$state_device" \
    || [ "$FM_PR_CI_FIX_COUNT_URL" != "$url" ] \
    || [ "$FM_PR_CI_FIX_COUNT" != "$next" ] \
    || ! fm_pr_regular_destination_on_device_or_absent "$file" "$state_device" \
    || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_ci_fix_count_file_valid "$file" "$state_device" \
    && [ "$FM_PR_CI_FIX_COUNT_URL" = "$url" ] \
    && [ "$FM_PR_CI_FIX_COUNT" = "$next" ]
}

fm_pr_ci_fix_count_remove() {  # <state> <task-id>
  local state=$1 id=$2 file state_device
  file=$(fm_pr_ci_fix_count_path "$state" "$id") || return 1
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 0
  fi
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_ci_fix_count_file_valid "$file" "$state_device" || return 1
  rm -f -- "$file" || return 1
  [ ! -e "$file" ] && [ ! -L "$file" ]
}
