#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits only actionable transitions and stays silent on every error, timeout,
# authentication failure, or malformed forge response.
# A merged PR or MR emits only `merged`.
# A GitHub PR can additionally emit `behind <head>` and one `ci-failed <head>
# <check-fingerprint>` line for each required check currently concluded in a
# blocking failure state.
# The provider-tagged identity is data in the sidecar and is never interpolated
# into this source, so these bytes are identical for every task.
# GitLab remains merge-only because its current glab response does not provide a
# portable required-check contract equivalent to GitHub's pull-request-scoped
# `isRequired` field.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

head_valid() {
  case "$1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]* ) ;;
    *) return 1 ;;
  esac
  [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
}

base64_token_valid() {
  local value=$1
  [ "${#value}" -ge 4 ] && [ "${#value}" -le 4096 ] || return 1
  [ $(( ${#value} % 4 )) -eq 0 ] || return 1
  case "$value" in *[!A-Za-z0-9+/=]*) return 1 ;; esac
}

check_failure_conclusion() {
  case "$1" in
    ACTION_REQUIRED|CANCELLED|FAILURE|STALE|STARTUP_FAILURE|TIMED_OUT) return 0 ;;
    *) return 1 ;;
  esac
}

check_fingerprint() {
  local value=$1 digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$value" | shasum -a 256 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$value" | sha256sum 2>/dev/null | awk '{print $1}')
  else
    return 1
  fi
  case "$digest" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]* ) ;; *) return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  case "$digest" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$digest"
}

poll_github() {
  local owner=$1 repo=$2 raw line kind required status conclusion encoded extra
  local state='' merge_status='' head='' meta_seen=0 complete_seen=0 failure identity fingerprint existing
  local -a failures
  local query jq_filter

  # shellcheck disable=SC2016 # GraphQL and jq variables are evaluated by gh.
  query='query($owner:String!, $name:String!, $number:Int!) { repository(owner:$owner, name:$name) { pullRequest(number:$number) { state mergeStateStatus headRefOid statusCheckRollup { contexts(first:100) { nodes { __typename ... on CheckRun { name isRequired(pullRequestNumber:$number) status conclusion } ... on StatusContext { context isRequired(pullRequestNumber:$number) state } } pageInfo { hasNextPage } } } } } }'
  # shellcheck disable=SC2016 # GraphQL and jq variables are evaluated by gh.
  jq_filter=' .data.repository.pullRequest as $pr
    | (($pr.statusCheckRollup // {}) | (.contexts // {})) as $contexts
    | if $contexts.pageInfo.hasNextPage == true then error("status checks exceed one page") else . end
    | (["meta", $pr.state, $pr.mergeStateStatus, $pr.headRefOid] | @tsv),
      (($contexts.nodes // [])[]?
        | if .__typename == "CheckRun" then
            ["check-run", (.isRequired | tostring), (.status // "null"), (.conclusion // "null"), (.name | @base64)] | @tsv
          elif .__typename == "StatusContext" then
            ["status-context", (.isRequired | tostring), (.state // "null"), (.context | @base64)] | @tsv
          else error("unknown status check context")
          end),
      "complete"'

  raw=$(gh api graphql -f query="$query" -F owner="$owner" -F name="$repo" -F number="$number" --jq "$jq_filter" 2>/dev/null) || return 0
  failures=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$complete_seen" -eq 0 ] || return 0
    case "$line" in
      complete)
        complete_seen=1
        ;;
      meta$'\t'*)
        [ "$meta_seen" -eq 0 ] || return 0
        IFS=$'\t' read -r kind state merge_status head extra <<EOF
$line
EOF
        [ -z "${extra:-}" ] || return 0
        case "$state" in OPEN|CLOSED|MERGED) ;; *) return 0 ;; esac
        case "$merge_status" in BEHIND|BLOCKED|CLEAN|DIRTY|HAS_HOOKS|UNKNOWN|UNSTABLE) ;; *) return 0 ;; esac
        head_valid "$head" || return 0
        meta_seen=1
        ;;
      check-run$'\t'*)
        [ "$meta_seen" -eq 1 ] || return 0
        IFS=$'\t' read -r kind required status conclusion encoded extra <<EOF
$line
EOF
        [ -z "${extra:-}" ] || return 0
        case "$required" in true|false) ;; *) return 0 ;; esac
        case "$status" in ''|*[!A-Z_]*) return 0 ;; esac
        case "$conclusion" in ''|*[!A-Z_]*|null) [ "$conclusion" = null ] || return 0 ;; esac
        base64_token_valid "$encoded" || return 0
        if [ "$required" = true ] && [ "$status" = COMPLETED ] && check_failure_conclusion "$conclusion"; then
          identity="check-run:$encoded"
          if [ "${#failures[@]}" -gt 0 ]; then
            for existing in "${failures[@]}"; do
              [ "$existing" != "$identity" ] || continue 2
            done
          fi
          failures+=("$identity")
        fi
        ;;
      status-context$'\t'*)
        [ "$meta_seen" -eq 1 ] || return 0
        IFS=$'\t' read -r kind required status encoded extra <<EOF
$line
EOF
        [ "$kind" = status-context ] && [ -z "${extra:-}" ] || return 0
        case "$required" in true|false) ;; *) return 0 ;; esac
        case "$status" in ''|*[!A-Z_]*) return 0 ;; esac
        base64_token_valid "$encoded" || return 0
        if [ "$required" = true ] && { [ "$status" = FAILURE ] || [ "$status" = ERROR ]; }; then
          identity="status-context:$encoded"
          if [ "${#failures[@]}" -gt 0 ]; then
            for existing in "${failures[@]}"; do
              [ "$existing" != "$identity" ] || continue 2
            done
          fi
          failures+=("$identity")
        fi
        ;;
      *) return 0 ;;
    esac
  done <<EOF
$raw
EOF

  [ "$meta_seen" -eq 1 ] && [ "$complete_seen" -eq 1 ] || return 0
  [ "$state" = MERGED ] && { printf '%s\n' merged; return 0; }
  [ "$state" = OPEN ] || return 0
  [ "$merge_status" != BEHIND ] || printf 'behind %s\n' "$head"
  if [ "${#failures[@]}" -gt 0 ]; then
    for failure in "${failures[@]}"; do
      fingerprint=$(check_fingerprint "$failure") || return 0
      printf 'ci-failed %s %s\n' "$head" "$fingerprint"
    done
  fi
}

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    poll_github "$owner" "$repo"
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
