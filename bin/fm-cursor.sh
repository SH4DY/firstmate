#!/usr/bin/env bash
# fm-cursor.sh - read, watch, steer, and create THIS operator's own Cursor Cloud
# agents.
#
# Cursor Cloud agents run on Cursor's infrastructure, not in a firstmate
# worktree or terminal endpoint, so they are deliberately NOT a runtime backend
# (bin/fm-backend.sh) and NOT a harness (bin/fm-harness.sh): there is no pane to
# capture, no composer to submit into, and no local checkout to isolate. This
# helper is the companion-surface pattern instead, the same boundary
# docs/codex-app-backend.md draws for Codex Desktop threads. It creates no task
# records and registers no watcher check, so no supervision path can mistake a
# cloud agent for a stalled local crewmate.
#
# The mapping onto firstmate's own nouns is: a Cursor AGENT is a task, and a
# Cursor ENVIRONMENT is the project. An environment is a named, multi-repo,
# secret-bearing context, and `POST /v1/agents` accepts either a named `env` or a
# bare `repos` list - the API documents them as mutually exclusive. An agent
# therefore belongs to its environment, never to one of the repositories inside
# it, and a change spanning a front end and a back end is one agent in one
# environment rather than several tasks. Both `list` and `show` lead with the
# environment for that reason; an agent created from a bare repo list has no
# environment name and is shown as the ad-hoc case.
#
# Usage:
#   fm-cursor.sh list   [--json] [--all] [--limit <n>] [--no-runs] [--env [<name>]]
#   fm-cursor.sh show   <agent-id> [--json]
#   fm-cursor.sh runs   <agent-id> [--json] [--limit <n>] [--no-result]
#   fm-cursor.sh usage  <agent-id> [--json]
#   fm-cursor.sh watch  <agent-id> [--run <run-id>] [--timeout <s>]
#                       [--attempts <n>] [--replay] [--json]
#   fm-cursor.sh send   <agent-id> <prompt...> [--json]
#   fm-cursor.sh cancel <agent-id> [--json]
#   fm-cursor.sh archive <agent-id> [--json]
#   fm-cursor.sh unarchive <agent-id> [--json]
#   fm-cursor.sh create [--env <name>] (--prompt <text> | --prompt-file <path>)
#                       [--model <id>] [--work-on-current-branch] [--json]
#   fm-cursor.sh -h | --help
#
# Read subcommands:
#   list   Agents newest-first, each with its ENVIRONMENT and the status of its
#          LATEST RUN. Archived agents are hidden unless --all is passed.
#   show   One agent's detail: its environment, every repository in that
#          environment, and the status of its latest run.
#   runs   Run history for one agent: status, start, duration, and any PR URL.
#   usage  Token usage for one agent: the totals and the run count. The per-run
#          breakdown is in --json only.
#   watch  Stream one run's events live, in the foreground, until it ends or the
#          timeout expires. This is the only way to see what a cloud run is doing
#          WHILE it runs: the Cloud Agents API has no conversation or messages
#          endpoint, so without this the choice is Cursor Web or nothing.
#
# Mutating subcommands, which act on the operator's LIVE fleet:
#   send      Queue a follow-up run on an existing agent.
#   cancel    Cancel that agent's active run.
#   archive   Archive an agent. Reversible; `unarchive` brings it back.
#   unarchive Restore an archived agent.
#   create    Start a new agent in an environment.
#
# Every mutating subcommand requires an explicit agent id: there is no "most
# recent" default and no wildcard, because steering the wrong agent is not undone
# by re-running the command. `DELETE /v1/agents/{id}` is deliberately NOT wired at
# all - it is permanent, `archive` covers every cleanup need, and `unarchive`
# makes it reversible.
#
# One run can be active per agent, so `send`, `cancel` and `archive` read the
# latest run status first and refuse with an explanation naming the run rather
# than firing a request the API would answer with `409 agent_busy`. A run that
# starts between that read and the write still yields a clean refusal, not a
# stack trace. When the run status cannot be determined at all, they refuse
# rather than risk interrupting live work.
#
# Options:
#   --json        Emit a stable JSON document instead of the human table.
#                 Schemas: fm-cursor-list.v1, fm-cursor-show.v1,
#                 fm-cursor-runs.v1, fm-cursor-usage.v1. `watch` streams instead:
#                 one fm-cursor-watch-event.v1 object per event as it arrives,
#                 then one fm-cursor-watch.v1 summary object last.
#   --all         list only: include ARCHIVED agents.
#   --limit <n>   list: agents to fetch, 1-100, default 20.
#                 runs: runs to fetch, 1-100, default 20.
#   --no-runs     list only: skip latest-run resolution. One API call instead of
#                 1+N, at the cost of the only column that says what is actually
#                 running.
#   --no-result   runs only: skip result hydration, so `result` carries whatever
#                 the list endpoint gave (in practice: nothing).
#   --run <id>    watch only: watch this run instead of the agent's latest.
#   --timeout <s> watch only: total seconds to watch, 5-21600, default 900. Also
#                 the hard bound on every connection, so nothing can outlive it.
#   --attempts <n>
#                 watch only: reconnections allowed after a dropped stream, 0-9,
#                 default 3. Each one resumes from the last event seen.
#   --replay      watch only: stream a run that has ALREADY ended. The stream
#                 replays that run's whole history, which is a full transcript
#                 and can be thousands of events, so it is opt-in.
#   --work-on-current-branch
#                 create only: commits land on the branch the agent checks out,
#                 instead of on a generated `cursor/...` branch. Combine with a
#                 checkout instruction in the prompt to put a cloud agent on an
#                 existing branch while still naming an environment.
#   --env [<name>]
#                 list only: show only agents in that environment. A bare --env
#                 means this home's default from config/cursor-environment, and
#                 fails when no default is configured. Cursor's list endpoint has
#                 no environment filter, so this narrows the fetched page
#                 client-side: --limit bounds the FETCH, not the matches, and the
#                 footer reports both counts. Filtering happens before run
#                 resolution, so a narrow --env costs far fewer requests.
#
# The default environment never filters implicitly. `list` always shows every
# environment and marks the default with `*`, because silently hiding most of the
# fleet would misrepresent it; the default is the intended TARGET for a future
# operation that needs an environment, not a view preference.
#
# Why list resolves runs by default: an agent's own `status` field is LIFECYCLE
# only - the enum is ACTIVE|ARCHIVED and the Cursor API documents it as "agent
# lifecycle state; execution status lives on runs". ACTIVE therefore means "not
# archived", NOT "currently running": a finished agent stays ACTIVE until
# somebody archives it. Reporting agent status as if it were execution status is
# the single easiest way to misread this fleet, so `list` resolves each agent's
# latest run and reports the run status enum
# (CREATING|RUNNING|FINISHED|ERROR|CANCELLED|EXPIRED) as the primary column.
# Resolution prefers the `latestRunId` field that list items carry in practice;
# that field is NOT in Cursor's published schema, so a per-agent
# `runs?limit=1` fallback covers both its absence AND a fast path whose request
# fails, and the JSON output records which source answered in `runStatusSource`:
# `latestRunId`, `runs-list`, `resolution-failed`, `none` for an agent that has no
# runs at all, or `skipped` for --no-runs. An agent with no runs reports run
# status `none`, which is a real observation - the agent exists and has never run -
# and is distinct from `unknown`, which means resolution failed and the run's state
# was never seen.
# Run resolution is deliberately NON-FATAL, in `show` exactly as in `list`. The
# fast path is reached through that undocumented field, so a stale value there
# says nothing about whether the agent exists, and exiting with "not found" for an
# agent whose own GET just succeeded would be actively misleading. A failed fast
# path therefore ALWAYS falls through to the fallback, and when both fail the run
# is reported as `unknown` WITH its reason - the HTTP status and the API's own
# message - so a 429 mid-listing can never be mistaken for a rejected key or for
# runs that are simply gone. `list` groups those reasons into its footer and
# degrades only the rows that failed; `--json` carries one per agent in
# `runStatusReason`. What still fails loudly is the TOP-LEVEL request of each
# subcommand - the agent list, one agent, its runs, its usage - because there a
# non-200 means the operation itself failed and nothing is left to show.
#
# Why `runs --json` hydrates the result: the LIST endpoint
# `/v1/agents/{id}/runs` omits `result` even for a FINISHED run, while
# `/v1/agents/{id}/runs/{runId}` returns it populated - verified live on
# 2026-08-01 against a finished run whose list item carried no result field at
# all. A consumer reading the list item therefore sees `result: null` and cannot
# tell "the agent said nothing" from "this endpoint does not carry it", which is
# how bin/fm-bare-metal.sh would silently write an EMPTY return handoff and lose
# the cloud agent's entire reasoning. So `runs --json` fetches the individual run
# for each listed run that is TERMINAL and whose list item has no result, and
# records where the answer came from in `resultSource`: `list-item` when the list
# carried it, `run-detail` when it was hydrated, `pending` for a run still going
# (no result exists yet), `absent` when the run itself reports none, `unavailable`
# when the hydrating request failed - with the reason in `resultReason` - or
# `skipped` under --no-result. Hydration is bounded and non-fatal: a run still
# running costs no extra request, a failed hydration degrades that one run, and
# the human table is unchanged because it never showed result text.
#
# Why `watch` is FOREGROUND-ONLY, and deliberately not a daemon: firstmate has
# exactly one watcher and no per-task daemons, and an SSE connection is inherently
# long-lived, which is exactly the shape that has wedged before. `watch` therefore
# runs in the foreground, prints to the terminal, and is bounded twice over: an
# overall --timeout deadline, and the same deadline handed to curl as --max-time
# on every connection so no connection can outlive the command. It creates no task
# record, arms no check, writes no state, and starts no background process, so
# there is nothing here for supervision to adopt or for a wedge to happen in.
#
# STREAMING IS AN ACCELERATOR, NEVER THE AUTHORITY. bin/fm-cloudify-arm-check.sh
# remains the only thing that guarantees firstmate learns a cloud run finished:
# `watch` does not touch it, is not armed by it, and is not consulted by it. When
# the stream and the poll disagree, the poll wins - which is why `watch` confirms
# its own outcome against `GET /v1/agents/{id}/runs/{runId}` before reporting,
# rather than trusting the last event it happened to see.
#
# Stream mechanics, all verified live on 2026-08-01:
#   - The stream REPLAYS the requested run from its beginning, and is scoped to
#     that one run; it never carries a different run's events.
#   - `Last-Event-ID` resumption works: a reconnect carrying the last id seen
#     continues immediately after that event rather than replaying from the start,
#     so a dropped connection costs nothing but the reconnect.
#   - The response carries `X-Cursor-Stream-Retention-Seconds` (86400 observed).
#     Past that window the stream is gone and answers `410 stream_expired`, so
#     `watch` reports the retention window rather than assuming a stream exists,
#     declines to resume once that window has passed, and falls back to the run
#     endpoint for terminal state on a 410.
#   - `heartbeat` is liveness only and is NEVER rendered as content.
#   - `interaction_update` is a delta channel that duplicates `assistant` and
#     `thinking` (`text-delta`, `thinking-delta`) plus accounting (`token-delta`,
#     step and tool-call lifecycle). It is counted, not printed, because printing
#     it would double every word the agent said. --json still carries all of it.
#
# No stream failure can fail the command: a drop, a 410, a rate limit, an expired
# window and a network outage all degrade to "no live view, the poll still works"
# with the reason named, and `watch` still exits 0. Only a usage error, a missing
# credential, or having no run to watch at all is an error.
#
# Activation: inert until this home opts in by putting a non-empty
# CURSOR_API_KEY in its gitignored .env, mirroring how X mode gates on
# FMX_PAIRING_TOKEN. The key is read from that file ONLY. This helper never
# consults the macOS keychain, `cursor-agent`'s stored credentials, or an ambient
# CURSOR_API_KEY in the environment: an undocumented credential lifted from
# another tool's store is not a supported Cursor credential, and an ambient
# variable would silently change which account firstmate speaks for.
#
# Credential handling: the key is passed to curl through a mode-0600 config file
# that is removed on every exit path, never through argv, because a process
# argument is world-readable via `ps`. The key is never printed, never logged,
# and never included in an error message; HTTP failures report the status code
# and the API's own `message` field only.
#
# The read verbs - list, show, runs, usage, watch - only ever issue GETs and
# cannot alter the operator's fleet. `watch` is a read verb: attaching to a run's
# stream observes it and never steers it.
#
# Files:
#   $FM_HOME/.env                     CURSOR_API_KEY, the activation gate
#   $FM_HOME/config/cursor-environment
#                                     optional default environment name: the
#                                     first non-empty, non-comment line, trimmed,
#                                     used verbatim. Absent means no default.
#
# Environment:
#   FM_HOME               home whose .env and config/ are read (default: this checkout)
#   FM_CURSOR_ENV_FILE    read the key from this .env-style file instead
#   FM_CONFIG_OVERRIDE    read config/ from this directory instead
#   FM_CURSOR_API_BASE    API base URL (default https://api.cursor.com)
#   FM_CURSOR_TIMEOUT     per-request timeout in seconds, a whole number from 1
#                         to 3600 (default 30). It bounds the ordinary requests;
#                         a `watch` stream is bounded by --timeout instead, since
#                         a live stream is expected to stay open.
#
# Exit status:
#   0  success, including every degraded `watch` outcome: a dropped stream, an
#      expired one, a rate limit, or a timeout is reported, never an error
#   2  usage error
#   3  not configured (no CURSOR_API_KEY), misconfigured (a key or timeout this
#      helper refuses to hand to curl), or a required tool is missing
#   4  the API rejected or failed the request
#   5  refused on purpose: the agent is busy, has nothing to act on, or its state
#      could not be determined, so no request was sent
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# fmx_env_get is the repo's single .env-style reader (last assignment wins,
# tolerates `export ` and one layer of quotes). Reuse it rather than rolling a
# second parser; bin/fm-public-followup-lib.sh depends on it the same way.
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
API_BASE=${FM_CURSOR_API_BASE:-https://api.cursor.com}
API_BASE=${API_BASE%/}
TIMEOUT=${FM_CURSOR_TIMEOUT:-30}

# This home's default environment, from config/cursor-environment: the first
# non-empty, non-comment line with surrounding whitespace trimmed, matching how
# bin/fm-harness.sh reads config/secondmate-harness. Absent file, or a file with
# only blank and comment lines, means this home has no default. The name is used
# verbatim otherwise, because Cursor environment names contain spaces and are
# case-sensitive.
default_environment() {
  local line
  [ -f "$CONFIG/cursor-environment" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s' "$line"
    return 0
  done < "$CONFIG/cursor-environment"
}

CFG=
BODY=
REQ=
SCFG=
STREAM_HDR=
cleanup() {
  [ -z "$CFG" ] || rm -f -- "$CFG"
  [ -z "$BODY" ] || rm -f -- "$BODY"
  [ -z "$REQ" ] || rm -f -- "$REQ"
  [ -z "$SCFG" ] || rm -f -- "$SCFG"
  [ -z "$STREAM_HDR" ] || rm -f -- "$STREAM_HDR"
}
trap cleanup EXIT HUP INT TERM

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {  # <exit-code> <message...>
  local code=$1
  shift
  printf 'fm-cursor: %s\n' "$*" >&2
  exit "$code"
}

require_tools() {
  local tool
  for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 \
      || die 3 "$tool is required (install: brew install $tool  # or the platform's package manager)"
  done
}

# The validated key, held only in this process and in the mode-0600 config files
# written from it. Loaded through a function that assigns rather than one that
# prints, because `die` inside a command substitution would exit the SUBSHELL and
# leave the caller running with an empty key.
API_KEY=
load_api_key() {
  local env_file token
  env_file=${FM_CURSOR_ENV_FILE:-$FM_HOME/.env}
  token=$(fmx_env_get CURSOR_API_KEY "$env_file")
  if [ -z "$token" ]; then
    die 3 "Cursor Cloud is not configured for this home. Put a non-empty CURSOR_API_KEY in $env_file (create the key at https://cursor.com/dashboard/api). Until then this helper does nothing."
  fi
  # Refuse a key carrying characters that curl config quoting would mangle or
  # that could inject a second directive. Real keys are URL-safe base64.
  case $token in
    *[!A-Za-z0-9._~+/=-]*)
      die 3 "the CURSOR_API_KEY in $env_file contains unexpected characters; re-copy it from https://cursor.com/dashboard/api" ;;
  esac
  API_KEY=$token
}

# Write one mode-0600 curl config carrying the bearer header and a max-time.
# Curl config syntax is one directive per line, so an unvalidated timeout is an
# injection point: a value holding a newline would append arbitrary directives
# (proxy, url, output) next to the key. Every caller therefore passes a
# valid_timeout-checked number.
write_curl_config() {  # <path> <max-time>
  printf 'header = "Authorization: Bearer %s"\nsilent\nshow-error\nmax-time = %s\n' \
    "$API_KEY" "$2" > "$1" || die 3 "could not write the API key file"
}

# Arm curl with the operator's key in a mode-0600 config file. The key never
# reaches argv, so it is not visible in `ps`.
arm_auth() {
  load_api_key
  # Digits only, and a range, so a typo fails legibly instead of degrading into
  # an opaque "could not reach" error.
  valid_timeout "$TIMEOUT" \
    || die 3 "FM_CURSOR_TIMEOUT must be a whole number of seconds from 1 to 3600"
  umask 077
  CFG=$(mktemp "${TMPDIR:-/tmp}/.fm-cursor-auth.XXXXXX") \
    || die 3 "could not create a private file for the API key"
  chmod 600 "$CFG" || die 3 "could not restrict permissions on the API key file"
  write_curl_config "$CFG" "$TIMEOUT"
  BODY=$(mktemp "${TMPDIR:-/tmp}/.fm-cursor-body.XXXXXX") \
    || die 3 "could not create a response file"
}

# A second config for `watch`, identical except that its max-time is the whole
# watch deadline. A stream is expected to stay open, so the ordinary per-request
# timeout would cut it off; a SEPARATE file rather than a command-line override
# keeps the ordinary requests this command still makes - resolving the run, and
# confirming the outcome afterwards - on their normal short timeout.
arm_stream_config() {  # <max-time>
  umask 077
  SCFG=$(mktemp "${TMPDIR:-/tmp}/.fm-cursor-stream.XXXXXX") \
    || die 3 "could not create a private file for the API key"
  chmod 600 "$SCFG" || die 3 "could not restrict permissions on the API key file"
  write_curl_config "$SCFG" "$1"
  STREAM_HDR=$(mktemp "${TMPDIR:-/tmp}/.fm-cursor-hdr.XXXXXX") \
    || die 3 "could not create a header file"
}

# GET <path>; leaves the response body in $BODY. Returns 0 only on HTTP 200, and
# otherwise returns non-zero with the explanation in $API_ERROR instead of
# exiting, so a caller can choose between dying and degrading one row of a view.
# The explanation carries the status and the API's own message, never raw headers.
API_ERROR=
api_try_get() {  # <path>
  local path=$1 code
  API_ERROR=
  code=$(curl --config "$CFG" -o "$BODY" -w '%{http_code}' "$API_BASE$path" 2>/dev/null) || code=000
  case $code in
    200) return 0 ;;
    000) API_ERROR="could not reach ${API_BASE} (network, proxy, or timeout after ${TIMEOUT}s)" ;;
    401|403) API_ERROR="the Cursor API rejected the key (HTTP $code)$(api_message). Check CURSOR_API_KEY, or regenerate it at https://cursor.com/dashboard/api" ;;
    404) API_ERROR="not found (HTTP 404)$(api_message)" ;;
    429) API_ERROR="rate limited by the Cursor API (HTTP 429)$(api_message). Retry in a minute" ;;
    *) API_ERROR="the Cursor API returned HTTP $code$(api_message)" ;;
  esac
  # Collapse to one line here, at the single point every explanation is built:
  # callers carry it through newline- and unit-separator-delimited records, and
  # the API's `message` field is data this helper does not control.
  API_ERROR=${API_ERROR//$'\n'/ }
  API_ERROR=${API_ERROR//$'\r'/ }
  API_ERROR=${API_ERROR//$'\t'/ }
  API_ERROR=${API_ERROR//$'\037'/ }
  return 1
}

# GET <path> or die. The right shape for a fetch whose failure leaves nothing to
# show: every top-level fetch, including the `list` page itself.
api_get() {  # <path>
  api_try_get "$1" || die 4 "$API_ERROR"
}

# POST <path> [json-body-file]; same credential path and error shaping as the GET
# helpers. Accepts 200 and 201, since create returns 201. Returns non-zero with
# $API_ERROR set rather than exiting, because the mutating callers turn a 409 into
# a clean refusal instead of an error.
#
# Request bodies are always built with `jq -n --arg`, never by interpolating text
# into a JSON string: a prompt is arbitrary operator text and would otherwise be
# able to close the quote and inject fields.
api_try_post() {  # <path> [body-file]
  local path=$1 body_file=${2:-} code
  API_ERROR=
  if [ -n "$body_file" ]; then
    code=$(curl --config "$CFG" -X POST -H 'Content-Type: application/json' \
      --data-binary "@$body_file" -o "$BODY" -w '%{http_code}' "$API_BASE$path" 2>/dev/null) || code=000
  else
    code=$(curl --config "$CFG" -X POST -o "$BODY" -w '%{http_code}' \
      "$API_BASE$path" 2>/dev/null) || code=000
  fi
  case $code in
    200|201) return 0 ;;
    000) API_ERROR="could not reach ${API_BASE} (network, proxy, or timeout after ${TIMEOUT}s)" ;;
    400) API_ERROR="the Cursor API rejected the request (HTTP 400)$(api_message)" ;;
    401|403) API_ERROR="the Cursor API rejected the key (HTTP $code)$(api_message). Check CURSOR_API_KEY, or regenerate it at https://cursor.com/dashboard/api" ;;
    404) API_ERROR="not found (HTTP 404)$(api_message)" ;;
    409) API_ERROR="conflict (HTTP 409)$(api_message)" ;;
    429) API_ERROR="rate limited by the Cursor API (HTTP 429)$(api_message). Retry in a minute" ;;
    *) API_ERROR="the Cursor API returned HTTP $code$(api_message)" ;;
  esac
  API_ERROR=${API_ERROR//$'\n'/ }
  API_ERROR=${API_ERROR//$'\r'/ }
  API_ERROR=${API_ERROR//$'\t'/ }
  API_ERROR=${API_ERROR//$'\037'/ }
  API_HTTP_CODE=$code
  return 1
}
API_HTTP_CODE=

# A scratch file for a request body, removed with the rest of the private files.
new_body_file() {
  umask 077
  REQ=$(mktemp "${TMPDIR:-/tmp}/.fm-cursor-req.XXXXXX") \
    || die 3 "could not create a private file for the request body"
  chmod 600 "$REQ" || die 3 "could not restrict permissions on the request body file"
}

# Refuse to act on an agent whose run is still going. One run can be active per
# agent, so the API would answer 409 agent_busy; reading first turns that into an
# explanation naming the run instead of a failed request. A caller still handles a
# real 409, because the run can start between this read and the write.
refuse_if_busy() {  # <agent-id> <verb>
  local agent=$1 verb=$2
  read_run_status_record "$(latest_run_status "$agent" "")"
  case $RUN_STATUS in
    RUNNING|CREATING)
      die 5 "agent $agent is busy: its latest run ${RUN_ID} is $RUN_STATUS, and only one run can be active at a time. Wait for it to finish, or cancel it first, then $verb again." ;;
    unknown)
      die 5 "cannot tell whether agent $agent is busy: $RUN_REASON. Refusing to $verb rather than risk interrupting a live run." ;;
  esac
}

# The API's own error text, when the body is JSON carrying one. Never the body
# wholesale, so a surprise payload cannot spill into a log.
api_message() {
  local msg
  msg=$(jq -r 'if type == "object" and (.message? | type) == "string" then .message else empty end' \
    "$BODY" 2>/dev/null) || return 0
  [ -n "$msg" ] || return 0
  printf ': %s' "$msg"
}

valid_agent_id() {  # <id>
  case $1 in
    '' | *[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

valid_limit() {  # <n>
  case $1 in
    '' | *[!0-9]*) return 1 ;;
    *) [ "$1" -ge 1 ] && [ "$1" -le 100 ] ;;
  esac
}

# Digits only, then a range. The 5-or-more-digit pattern is refused before any
# arithmetic so an absurd value cannot reach `[ -ge ]` at all.
valid_timeout() {  # <seconds>
  case $1 in
    '' | *[!0-9]* | ?????*) return 1 ;;
    *) [ "$1" -ge 1 ] && [ "$1" -le 3600 ] ;;
  esac
}

# One resolution record: status, run id, provenance, and the reason the status is
# `unknown`, joined by unit separators so a reason containing spaces survives.
run_status_record() {  # <status> <run-id> <source> [reason]
  printf '%s\037%s\037%s\037%s' "$1" "$2" "$3" "${4:-}"
}
RUN_STATUS=
RUN_ID=
RUN_SOURCE=
RUN_REASON=

# Read one record back into RUN_STATUS, RUN_ID, RUN_SOURCE, and RUN_REASON.
read_run_status_record() {  # <record>
  IFS=$(printf '\037') read -r RUN_STATUS RUN_ID RUN_SOURCE RUN_REASON <<EOF
$1
EOF
}

# Latest run status for one agent, as a run_status_record.
# Prefers the caller-supplied latestRunId, falls back to the runs list, and
# reports "none" for an agent that has no run yet.
#
# A failed fast-path request ALWAYS falls through to the runs-list fallback: the
# latestRunId that drove it is not in Cursor's published schema, so a stale or
# removed run id answering 404 says nothing about the agent itself. When the
# fallback fails too, resolution reports `unknown` with the reason attached and
# never exits, in every caller: `list` degrades that one row and keeps going, and
# `show` renders the agent it already fetched successfully rather than dying with
# a status that would read as "no such agent".
latest_run_status() {  # <agent-id> <latest-run-id-or-empty>
  local agent=$1 run=$2 status
  if [ -n "$run" ] && [ "$run" != null ]; then
    if valid_agent_id "$run"; then
      if api_try_get "/v1/agents/$agent/runs/$run"; then
        status=$(jq -r '.status // "none"' "$BODY")
        run_status_record "$status" "$run" latestRunId
        return 0
      fi
    fi
  fi
  if ! api_try_get "/v1/agents/$agent/runs?limit=1"; then
    run_status_record unknown none resolution-failed "$API_ERROR"
    return 0
  fi
  status=$(jq -r '(.items // [])[0].status // "none"' "$BODY")
  run=$(jq -r '(.items // [])[0].id // "none"' "$BODY")
  if [ "$status" = none ]; then
    run_status_record none none none
  else
    run_status_record "$status" "$run" runs-list
  fi
}

# Display label for the agent's environment, which is where the work actually
# lives. A named environment prints its name; an agent created from a bare repo
# list has no name, so it prints as the ad-hoc case rather than as a blank that
# would read like missing data.
env_label() {  # <env-name> <env-type>
  if [ -n "$1" ]; then
    printf '%s' "$1"
  else
    printf '(ad-hoc %s)' "${2:-cloud}"
  fi
}

# Footer for an --env-narrowed view. Emitted whatever the match count is,
# including zero: Cursor's list endpoint has no environment filter, so --limit
# bounds the FETCH and a missing match may simply be on the next page. Reporting
# only "none found" would read as "this home has no cloud agents".
filtered_footer() {  # <matched> <fetched> <env-name>
  printf 'Filtered to environment %s: %s of %s fetched agent(s) match. --limit bounds the fetch, not the matches, so raise it if a match is missing.\n' \
    "$3" "$1" "$2"
  if [ "$1" -eq 0 ] && [ "$2" -gt 0 ]; then
    printf 'Agents were fetched, so this is not an empty fleet: none of the %s fetched is in %s. Drop --env to see every environment.\n' \
      "$2" "$3"
  fi
}

cmd_list() {
  local json=0 include_archived=false limit=20 resolve_runs=1 env_filter='' filtering=0
  local default_env
  default_env=$(default_environment)
  while [ "$#" -gt 0 ]; do
    case $1 in
      --json) json=1 ;;
      --all) include_archived=true ;;
      --no-runs) resolve_runs=0 ;;
      --env)
        # Optional argument: a bare --env means "this home's default".
        filtering=1
        if [ "$#" -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ]; then
          env_filter=$2
          shift
        elif [ "$#" -ge 2 ] && [ -z "$2" ]; then
          # An empty name would quietly select the ad-hoc agents, whose envName is
          # "". Refuse instead of guessing which of the two was meant.
          die 2 "--env needs a non-empty environment name; omit the name to use this home's default"
        else
          [ -n "$default_env" ] || die 2 "--env with no name needs a default environment in $CONFIG/cursor-environment; pass --env <name> instead"
          env_filter=$default_env
        fi
        ;;
      --env=*)
        filtering=1
        env_filter=${1#--env=}
        [ -n "$env_filter" ] || die 2 "--env= needs a name"
        ;;
      --limit)
        [ "$#" -ge 2 ] || die 2 "--limit needs a value"
        valid_limit "$2" || die 2 "--limit must be a whole number from 1 to 100"
        limit=$2
        shift
        ;;
      --limit=*)
        valid_limit "${1#--limit=}" || die 2 "--limit must be a whole number from 1 to 100"
        limit=${1#--limit=}
        ;;
      *) die 2 "unknown option for list: $1" ;;
    esac
    shift
  done

  api_get "/v1/agents?limit=$limit&includeArchived=$include_archived"
  local agents fetched
  agents=$(jq -c '[(.items // [])[] | {
      id, name: (.name // ""), lifecycle: (.status // "UNKNOWN"),
      latestRunId: (.latestRunId // ""), createdAt: (.createdAt // ""),
      updatedAt: (.updatedAt // ""), url: (.url // ""),
      envType: (.env.type // ""), envName: (.env.name // ""),
      repos: [(.repos // [])[] | .url]
    }]' "$BODY")
  fetched=$(printf '%s' "$agents" | jq 'length')

  # Filter BEFORE resolving runs: run resolution costs one request per agent, so
  # narrowing first is the difference between one extra request and N.
  if [ "$filtering" -eq 1 ]; then
    agents=$(printf '%s' "$agents" | jq -c --arg e "$env_filter" 'map(select(.envName == $e))')
  fi

  # Resolve each agent's latest run one at a time. Serial on purpose: a burst of
  # parallel requests is the fastest way to meet the API's rate limiter. The ids
  # come out of one jq pass and the resolved records are stitched back on in one
  # more, rather than rebuilding the whole accumulating array once per agent.
  local resolved='[]'
  if [ "$resolve_runs" -eq 1 ]; then
    local statuses='' agent_id run_id record
    while IFS=$(printf '\t') read -r agent_id run_id; do
      # One record per line, unconditionally: the stitch below matches records to
      # agents by position, so skipping an unusable row would shift every status
      # after it onto the wrong agent.
      if valid_agent_id "$agent_id"; then
        record=$(latest_run_status "$agent_id" "$run_id")
      else
        record=$(run_status_record none none none)
      fi
      statuses="$statuses$record"$'\n'
    done <<EOF
$(printf '%s' "$agents" | jq -r '.[] | [.id, .latestRunId] | @tsv')
EOF
    resolved=$(printf '%s' "$agents" | jq -c --arg statuses "$statuses" '
      ($statuses | split("\n") | map(select(length > 0) | split("\u001f"))) as $t
      | to_entries
      | map(.value + {
          runStatus: $t[.key][0], runId: $t[.key][1], runStatusSource: $t[.key][2],
          runStatusReason: (if ($t[.key][3] // "") == "" then null else $t[.key][3] end)
        })')
  else
    resolved=$(printf '%s' "$agents" | jq -c \
      'map(. + {
        runStatus: "unresolved", runId: "", runStatusSource: "skipped",
        runStatusReason: null
      })')
  fi

  if [ "$json" -eq 1 ]; then
    printf '%s' "$resolved" | jq \
      --arg base "$API_BASE" --argjson archived "$include_archived" \
      --arg defaultEnv "$default_env" --arg envFilter "$env_filter" \
      --argjson fetched "$fetched" \
      --argjson resolvedRuns "$([ "$resolve_runs" -eq 1 ] && echo true || echo false)" '{
        schema: "fm-cursor-list.v1",
        base: $base,
        archivedIncluded: $archived,
        runsResolved: $resolvedRuns,
        defaultEnvironment: (if $defaultEnv == "" then null else $defaultEnv end),
        environmentFilter: (if $envFilter == "" then null else $envFilter end),
        fetched: $fetched,
        count: length,
        summary: {
          running: [.[] | select(.runStatus == "RUNNING" or .runStatus == "CREATING")] | length,
          multiRepo: [.[] | select((.repos | length) > 1)] | length,
          namedEnvironments: ([.[] | select(.envName != "") | .envName] | unique),
          byLifecycle: (group_by(.lifecycle) | map({key: .[0].lifecycle, value: length}) | from_entries),
          byRunStatus: (group_by(.runStatus) | map({key: .[0].runStatus, value: length}) | from_entries),
          byEnvironment: (group_by(.envName)
            | map({key: (if .[0].envName == "" then "(ad-hoc)" else .[0].envName end), value: length})
            | from_entries)
        },
        agents: .
      }'
    return 0
  fi

  # One pass for every count the footer needs, rather than one jq per number.
  local counts count running named unresolved
  counts=$(printf '%s' "$resolved" | jq -r '[
      length,
      ([.[] | select(.runStatus == "RUNNING" or .runStatus == "CREATING")] | length),
      ([.[] | select(.envName != "") | .envName] | unique | length),
      ([.[] | select(.runStatusSource == "resolution-failed")] | length)
    ] | @tsv')
  IFS=$(printf '\t') read -r count running named unresolved <<EOF
$counts
EOF

  if [ "$count" -eq 0 ]; then
    echo "No Cursor Cloud agents found."
    # An empty FILTERED view is a different fact from an empty fleet, and the
    # --limit caveat matters most exactly here: the match may be one page away.
    if [ "$filtering" -eq 1 ]; then
      filtered_footer "$count" "$fetched" "$env_filter"
    fi
    return 0
  fi

  # LIFECYCLE earns a column only with --all: without it every listed agent is
  # ACTIVE by construction, so the column would be a constant.
  local row_fmt='%-9s %-10s %-16s %-20s %5s  %s\n'
  if [ "$include_archived" = true ]; then
    row_fmt='%-9s %-10s %-9s %-16s %-20s %5s  %s\n'
    # shellcheck disable=SC2059  # row_fmt is a trusted local format string
    printf "$row_fmt" AGENT RUN LIFECYCLE UPDATED ENVIRONMENT REPOS NAME
  else
    # shellcheck disable=SC2059
    printf "$row_fmt" AGENT RUN UPDATED ENVIRONMENT REPOS NAME
  fi
  # One jq pass renders every cell, including the environment label, its
  # truncation, and the default marker, then the read loop only pads columns.
  # A unit separator rather than a tab, because tab is IFS whitespace to `read`
  # and an empty middle cell - an agent with no updatedAt - would collapse the
  # row by one column.
  local sep
  sep=$(printf '\037')
  # Truncate the environment label first, then append the default marker, so a
  # long environment name can never swallow the marker the way it would if the
  # assembled label were cut to width.
  printf '%s' "$resolved" | jq -r --arg defaultEnv "$default_env" --arg sep "$sep" '
    def trunc($w): if length > $w then .[0:($w - 3)] + "..." else . end;
    # `.name` and `.envName` are API-controlled strings, so they get the same
    # treatment api_try_get gives the API message field before it enters a
    # separator-delimited record: a name carrying the record separator, a newline,
    # CR or tab would otherwise split or truncate the row it appears in.
    #
    # The separator is split on literally, via jq`s one-argument split and the
    # separator passed in as $sep, rather than named by an escape inside a regex
    # character class. `[\\u001f...]` does NOT mean U+001F there - it is a literal
    # backslash plus `u`, so the class silently matches the letters u, n, r, t and
    # the digits 0, 1, f, which turns "cloud" into "clo d".
    def clean: split($sep) | join(" ") | gsub("[\n\r\t]"; " ");
    .[]
    | ((if .envName != "" then (.envName | clean)
        else "(ad-hoc " + (if .envType != "" then (.envType | clean) else "cloud" end) + ")" end)
       | trunc(18)) as $envl
    | [
        .id,
        .runStatus,
        (.lifecycle | ascii_downcase),
        (.updatedAt | gsub("T"; " ") | .[0:16]),
        (if $defaultEnv != "" and .envName == $defaultEnv then $envl + " *" else $envl end),
        (.repos | length | tostring),
        (.name | clean | trunc(34))
      ] | join("\u001f")' |
  while IFS="$sep" read -r id run life upd envl repos name; do
    if [ "$include_archived" = true ]; then
      # shellcheck disable=SC2059
      printf "$row_fmt" "${id: -8}" "$run" "$life" "$upd" "$envl" "$repos" "$name"
    else
      # shellcheck disable=SC2059
      printf "$row_fmt" "${id: -8}" "$run" "$upd" "$envl" "$repos" "$name"
    fi
  done

  echo
  # Only ever claim an in-flight count for runs actually OBSERVED. Under
  # --no-runs nothing was resolved, and a degraded row's run was never seen, so
  # asserting "0 with a run in flight" in either case would let an unresolved or
  # unknown row read as idle - the exact misread this view exists to prevent, and
  # the one the skill forbids folding into a "nothing running" count.
  printf '%s agent(s) shown' "$count"
  if [ "$resolve_runs" -eq 0 ]; then
    printf ', none of whose runs were resolved'
  else
    printf ', %s observed with a run in flight' "$running"
    [ "$unresolved" -eq 0 ] || printf ' and %s whose run could not be observed' "$unresolved"
  fi
  [ "$named" -eq 0 ] || printf ', across %s named environment(s)' "$named"
  printf '.\n'
  if [ "$filtering" -eq 1 ]; then
    filtered_footer "$count" "$fetched" "$env_filter"
  fi
  if [ "$resolve_runs" -eq 1 ]; then
    echo 'RUN is the latest run status and is what says whether work is happening.'
    if [ "$unresolved" -gt 0 ]; then
      printf 'RUN is unknown for %s agent(s) whose latest run could not be fetched; every other row is unaffected.\n' \
        "$unresolved"
      # Name the reasons, grouped, so a mid-listing 429 reads as rate limiting and
      # can never look identical to a rejected key or to runs that are simply gone.
      printf '%s' "$resolved" | jq -r '
        [.[] | select(.runStatusSource == "resolution-failed")
             | (.runStatusReason // "no reason reported")]
        | group_by(.) | map({reason: .[0], n: length}) | sort_by(-.n)[]
        | "  " + (.n | tostring) + " of them: " + .reason'
    fi
  else
    echo 'RUN was not resolved (--no-runs), so nothing here says whether work is happening.'
  fi
  if [ "$include_archived" = true ]; then
    echo 'LIFECYCLE active means "not archived" - a finished agent stays active until archived.'
  else
    echo 'Every agent listed is unarchived, which says nothing about whether it ran; pass --all to include archived ones.'
  fi
  echo 'ENVIRONMENT is where the work runs and carries that environment'"'"'s repositories and secrets; REPOS is how many repositories it spans.'
  echo 'An agent belongs to its environment, not to any single repository; use show for the repository list.'
  if [ -n "$default_env" ]; then
    if [ "$filtering" -eq 1 ]; then
      printf '* marks this home'"'"'s default environment, %s, from config/cursor-environment.\n' "$default_env"
    else
      printf '* marks this home'"'"'s default environment, %s, from config/cursor-environment; every environment is still listed.\n' "$default_env"
      printf 'Pass --env to narrow to %s, or --env <name> for another environment.\n' "$default_env"
    fi
  fi
  printf 'Agent ids are shown short; use the full id from --json with show, runs, or usage.\n'
}

cmd_show() {
  local json=0 agent=''
  while [ "$#" -gt 0 ]; do
    case $1 in
      --json) json=1 ;;
      -*) die 2 "unknown option for show: $1" ;;
      *)
        [ -z "$agent" ] || die 2 "show takes exactly one agent id"
        agent=$1
        ;;
    esac
    shift
  done
  [ -n "$agent" ] || die 2 "show needs an agent id (see: fm-cursor.sh list)"
  valid_agent_id "$agent" || die 2 "not a valid agent id: $agent"

  api_get "/v1/agents/$agent"
  local agent_json
  agent_json=$(jq -c '.' "$BODY")
  read_run_status_record \
    "$(latest_run_status "$agent" "$(printf '%s' "$agent_json" | jq -r '.latestRunId // ""')")"

  if [ "$json" -eq 1 ]; then
    printf '%s' "$agent_json" | jq \
      --arg s "$RUN_STATUS" --arg r "$RUN_ID" --arg src "$RUN_SOURCE" \
      --arg reason "$RUN_REASON" '{
        schema: "fm-cursor-show.v1",
        latestRun: {
          status: $s, id: $r, source: $src,
          reason: (if $reason == "" then null else $reason end)
        },
        agent: .
      }'
    return 0
  fi

  local env_name env_type repo_count
  env_name=$(printf '%s' "$agent_json" | jq -r '.env.name // ""')
  env_type=$(printf '%s' "$agent_json" | jq -r '.env.type // ""')
  repo_count=$(printf '%s' "$agent_json" | jq '(.repos // []) | length')

  printf '%s\n' "$(printf '%s' "$agent_json" | jq -r '.name // "(unnamed)"')"
  printf '  id           %s\n' "$(printf '%s' "$agent_json" | jq -r '.id')"
  printf '  environment  %s (%s)\n' "$(env_label "$env_name" "$env_type")" "${env_type:-unknown}"
  if [ -n "$RUN_REASON" ]; then
    printf '  latest run   %s (%s)\n' "$RUN_STATUS" "$RUN_REASON"
  else
    printf '  latest run   %s\n' "$RUN_STATUS"
  fi
  printf '  lifecycle    %s\n' "$(printf '%s' "$agent_json" | jq -r '.status // "UNKNOWN" | ascii_downcase')"
  printf '  created      %s\n' "$(printf '%s' "$agent_json" | jq -r '.createdAt // "-"')"
  printf '  updated      %s\n' "$(printf '%s' "$agent_json" | jq -r '.updatedAt // "-"')"
  printf '  url          %s\n' "$(printf '%s' "$agent_json" | jq -r '.url // "-"')"
  printf '  repositories %s in this environment\n' "$repo_count"
  printf '%s' "$agent_json" | jq -r '(.repos // [])[] | "                 " + .url'
  echo
  if [ -n "$env_name" ]; then
    printf 'This agent runs in the %s environment, which carries its own repositories and secrets; it does not belong to any single repository.\n' "$env_name"
    local default_env
    default_env=$(default_environment)
    if [ -n "$default_env" ] && [ "$env_name" = "$default_env" ]; then
      echo 'That is this home'"'"'s default environment from config/cursor-environment.'
    fi
  else
    echo 'This agent was created from a repository list rather than a named environment, so it carries no predefined environment secrets.'
  fi
  echo 'lifecycle active means "not archived"; the latest run status above is what says whether work is happening.'
  if [ -n "$RUN_REASON" ]; then
    echo 'That latest run status is unknown because the request for it failed, not because the agent is idle; everything above it came back fine.'
  fi
}

cmd_runs() {
  local json=0 agent='' limit=20 hydrate=1
  while [ "$#" -gt 0 ]; do
    case $1 in
      --json) json=1 ;;
      --no-result) hydrate=0 ;;
      --limit)
        [ "$#" -ge 2 ] || die 2 "--limit needs a value"
        valid_limit "$2" || die 2 "--limit must be a whole number from 1 to 100"
        limit=$2
        shift
        ;;
      --limit=*)
        valid_limit "${1#--limit=}" || die 2 "--limit must be a whole number from 1 to 100"
        limit=${1#--limit=}
        ;;
      -*) die 2 "unknown option for runs: $1" ;;
      *)
        [ -z "$agent" ] || die 2 "runs takes exactly one agent id"
        agent=$1
        ;;
    esac
    shift
  done
  [ -n "$agent" ] || die 2 "runs needs an agent id (see: fm-cursor.sh list)"
  valid_agent_id "$agent" || die 2 "not a valid agent id: $agent"

  api_get "/v1/agents/$agent/runs?limit=$limit"
  if [ "$json" -eq 1 ]; then
    # The list endpoint omits `result`, so every consumer that needs the agent's
    # final text - bin/fm-bare-metal.sh's return handoff above all - would read
    # null and cannot tell "said nothing" from "not carried here". Classify first
    # in one pass, then hydrate only the runs that genuinely need a request.
    local runs
    runs=$(jq -c --argjson hydrate "$hydrate" '[(.items // [])[] | {
        id, status, createdAt, updatedAt, durationMs,
        result: (.result // null),
        resultSource: (
          if (.result // null) != null then "list-item"
          elif $hydrate == 0 then "skipped"
          elif (.status // "") == "CREATING" or (.status // "") == "RUNNING" then "pending"
          else "needs-hydration" end),
        resultReason: null,
        branches: [(.git.branches // [])[] | {repoUrl, branch, prUrl}]
      }]' "$BODY")
    local idx run_id
    while IFS=$(printf '\t') read -r idx run_id; do
      [ -n "$idx" ] || continue
      if ! valid_agent_id "$run_id"; then
        runs=$(printf '%s' "$runs" | jq -c --argjson k "$idx" \
          '.[$k] |= (.resultSource = "unavailable" | .resultReason = "the run id is not a usable id")')
        continue
      fi
      if api_try_get "/v1/agents/$agent/runs/$run_id"; then
        local merged=''
        # A body that is not the expected JSON must degrade this one run rather
        # than abort the history, so the merge is attempted, not assumed.
        merged=$(printf '%s' "$runs" | jq -c --argjson k "$idx" --slurpfile d "$BODY" '
          ($d[0].result // null) as $r
          | .[$k] |= (.result = $r
              | .resultSource = (if $r == null then "absent" else "run-detail" end))' 2>/dev/null) || merged=''
        if [ -n "$merged" ]; then
          runs=$merged
        else
          runs=$(printf '%s' "$runs" | jq -c --argjson k "$idx" \
            '.[$k] |= (.resultSource = "unavailable" | .resultReason = "the run detail response was not readable JSON")')
        fi
      else
        # Non-fatal, exactly like run-status resolution: one run degrades and
        # carries its reason, and the rest of the history is unaffected.
        runs=$(printf '%s' "$runs" | jq -c --argjson k "$idx" --arg why "$API_ERROR" \
          '.[$k] |= (.resultSource = "unavailable" | .resultReason = $why)')
      fi
    done <<EOF
$(printf '%s' "$runs" | jq -r 'to_entries[]
  | select(.value.resultSource == "needs-hydration")
  | [(.key | tostring), .value.id] | @tsv')
EOF
    # `needs-hydration` is an internal marker and must never reach a consumer.
    # Every entry carrying it was visited above, so this is a belt on top of the
    # braces: if one ever survived, it means the request never happened.
    printf '%s' "$runs" | jq --arg a "$agent" '{
      schema: "fm-cursor-runs.v1",
      agentId: $a,
      count: length,
      runs: map(if .resultSource == "needs-hydration"
                then .resultSource = "unavailable"
                   | .resultReason = "the run detail request was never made"
                else . end)
    }'
    return 0
  fi

  local count
  count=$(jq '(.items // []) | length' "$BODY")
  if [ "$count" -eq 0 ]; then
    echo "No runs on this agent yet."
    return 0
  fi
  printf '%-9s %-10s %-16s %-9s %s\n' RUN STATUS STARTED DURATION PR
  jq -r '
    def dur: if . == null then "-"
      else (. / 1000 | floor) as $s
        | if $s < 60 then ($s | tostring) + "s"
          else (($s / 60 | floor) | tostring) + "m" + (($s % 60) | tostring) + "s" end
      end;
    (.items // [])[] | [
      (.id // "-"), (.status // "-"), (.createdAt // "-"), (.durationMs | dur),
      ([(.git.branches // [])[] | .prUrl // empty] | if length == 0 then "-" else join(" ") end)
    ] | @tsv' "$BODY" |
  while IFS=$(printf '\t') read -r rid status started dur pr; do
    printf '%-9s %-10s %-16s %-9s %s\n' \
      "${rid: -8}" "$status" "$(printf '%s' "$started" | tr T ' ' | cut -c1-16)" "$dur" "$pr"
  done
  echo
  echo 'Each follow-up prompt to an agent is a new run; only one run can be active at a time.'
  echo 'A PR URL belongs to the pull request itself, not necessarily to the first repository listed for the agent.'
  echo 'Run ids are shown short; use --json for the full ids.'
}

cmd_usage() {
  local json=0 agent=''
  while [ "$#" -gt 0 ]; do
    case $1 in
      --json) json=1 ;;
      -*) die 2 "unknown option for usage: $1" ;;
      *)
        [ -z "$agent" ] || die 2 "usage takes exactly one agent id"
        agent=$1
        ;;
    esac
    shift
  done
  [ -n "$agent" ] || die 2 "usage needs an agent id (see: fm-cursor.sh list)"
  valid_agent_id "$agent" || die 2 "not a valid agent id: $agent"

  api_get "/v1/agents/$agent/usage"
  if [ "$json" -eq 1 ]; then
    # costAvailable is a capability fact, not an opinion: the Cloud Agents API
    # exposes no price or charge field anywhere, so a consumer should not hunt
    # for one. Money lives only on the Admin API, behind an admin-only key.
    jq --arg a "$agent" '{
      schema: "fm-cursor-usage.v1",
      agentId: $a,
      costAvailable: false,
      totalUsage: (.totalUsage // {}),
      runs: [(.runs // [])[] | {id, usage}]
    }' "$BODY"
    return 0
  fi

  printf 'Token usage for %s across %s run(s)\n' "$agent" "$(jq '(.runs // []) | length' "$BODY")"
  jq -r '(.totalUsage // {}) | to_entries[] | [.key, (.value | tostring)] | @tsv' "$BODY" |
  while IFS=$(printf '\t') read -r label value; do
    printf '  %-17s %s\n' "$label" "$value"
  done
  echo
  echo 'Cursor reports tokens only; this API exposes no cost figure, so firstmate cannot report spend here.'
}

# --- watch: one run's event stream, in the foreground ------------------------
#
# The header owns the rationale. The invariants this code has to keep are:
# nothing here outlives the command, nothing here is authoritative over the
# watcher poll, and nothing here can turn a stream problem into a failure.

WATCH_JSON=0
WATCH_AGENT=
WATCH_RUN=
WATCH_SEQ=0
LAST_EVENT_ID=
STREAM_TERMINAL=0
STREAM_HTTP=
STREAM_RETENTION=
STREAM_EVENTS=0
STREAM_HEARTBEATS=0
STREAM_TOKENS=0
STREAM_TOOLS=0
LAST_TOOL=
AT_COL0=1
CHANNEL=

valid_attempts() {  # <n>
  case $1 in
    '' | *[!0-9]* | ??*) return 1 ;;
    *) [ "$1" -ge 0 ] && [ "$1" -le 9 ] ;;
  esac
}

valid_watch_timeout() {  # <seconds>
  case $1 in
    '' | *[!0-9]* | ??????*) return 1 ;;
    *) [ "$1" -ge 5 ] && [ "$1" -le 21600 ] ;;
  esac
}

# Escape one shell string into JSON string CONTENT, without forking. --json emits
# one object per event and a busy run emits thousands, so a jq per event would
# turn a live view into a slideshow. The remaining C0 controls are dropped rather
# than passed through, because a raw control byte inside a JSON string is invalid
# JSON and this text comes from the API, not from us.
json_escape() {  # <text>
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037'$'\177']/}
  printf '%s' "$s"
}

# One event as one line of JSON. `data` is passed through as JSON when it looks
# like a JSON object or array, which is what every documented event payload is,
# and is emitted as a string otherwise so an unexpected payload still produces a
# readable line instead of a broken one.
emit_json_event() {  # <event> <event-id> <data>
  local data=$3
  WATCH_SEQ=$((WATCH_SEQ + 1))
  printf '{"schema":"fm-cursor-watch-event.v1","agentId":"%s","runId":"%s","seq":%s,"eventId":"%s","event":"%s","data":' \
    "$(json_escape "$WATCH_AGENT")" "$(json_escape "$WATCH_RUN")" "$WATCH_SEQ" \
    "$(json_escape "$2")" "$(json_escape "$1")"
  case $data in
    '{'*|'['*) printf '%s' "${data//$'\n'/ }" ;;
    '') printf 'null' ;;
    *) printf '"%s"' "$(json_escape "$data")" ;;
  esac
  printf '}\n'
}

# The value of one SSE field line: everything after the colon, with at most one
# leading space removed, per the event-stream format.
sse_value() {  # <line>
  local v=${1#*:}
  printf '%s' "${v# }"
}

# Human rendering keeps a cursor position, because the text channels stream
# deltas without newlines and every other line has to start at column 0.
begin_line() {
  [ "$AT_COL0" -eq 1 ] || printf '\n'
  AT_COL0=1
  CHANNEL=
}

text_out() {  # <channel> <text>
  if [ "$1" != "$CHANNEL" ]; then
    begin_line
    printf '[%s] ' "$1"
    CHANNEL=$1
  fi
  printf '%s' "$2"
  case $2 in
    *$'\n') AT_COL0=1 ;;
    *) AT_COL0=0 ;;
  esac
}

# One string field out of an event payload, tolerating a payload that is not an
# object at all. Never fatal: an odd event must not end the watch.
#
# The value lands in FIELD_VALUE rather than on stdout because a text delta can be
# nothing but newlines - the blank line between an agent's paragraphs arrives as
# its own event - and a command substitution strips trailing newlines, which
# silently ran those paragraphs together. A sentinel protects the value inside the
# one substitution that is unavoidable, and is removed before use.
FIELD_VALUE=
event_field() {  # <data> <field>
  local v
  FIELD_VALUE=
  v=$(printf '%s' "$1" | jq -r --arg f "$2" \
    'if type == "object" and (.[$f] | type) == "string" then (.[$f] + "\u0003") else empty end' 2>/dev/null) || v=
  case $v in
    *$'\003') FIELD_VALUE=${v%$'\003'} ;;
  esac
}

render_tool_call() {  # <data>
  local line
  line=$(printf '%s' "$1" | jq -r 'if type == "object"
      then ((.name // "?") + " " + (.status // "?")) else "?" end' 2>/dev/null) || line='?'
  line=${line//$'\n'/ }
  # tool_call repeats as one call changes state, so print transitions only.
  [ "$line" != "$LAST_TOOL" ] || return 0
  LAST_TOOL=$line
  STREAM_TOOLS=$((STREAM_TOOLS + 1))
  begin_line
  printf '[tool] %s\n' "$line"
}

dispatch_event() {  # <event> <data> <event-id>
  local ev=$1 data=$2 eid=$3 txt
  # A blank line with nothing accumulated is a keep-alive boundary, not an event.
  [ -n "$ev" ] || [ -n "$data" ] || return 0
  [ -n "$ev" ] || ev=message
  [ -z "$eid" ] || LAST_EVENT_ID=$eid
  STREAM_EVENTS=$((STREAM_EVENTS + 1))

  case $ev in
    heartbeat)
      # Liveness only, in both modes. A heartbeat is not content and is never
      # rendered as if the agent had said something.
      STREAM_HEARTBEATS=$((STREAM_HEARTBEATS + 1)) ;;
    interaction_update)
      # The delta channel that duplicates assistant and thinking, plus token and
      # lifecycle accounting. Counted here with a bash match rather than a jq
      # call, because it is the highest-volume event by far.
      if [[ $data =~ \"tokens\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
        STREAM_TOKENS=$((STREAM_TOKENS + BASH_REMATCH[1]))
      fi ;;
    done|error) STREAM_TERMINAL=1 ;;
  esac

  if [ "$WATCH_JSON" -eq 1 ]; then
    emit_json_event "$ev" "$eid" "$data"
    return 0
  fi

  case $ev in
    heartbeat|interaction_update) ;;
    assistant)
      event_field "$data" text
      [ -z "$FIELD_VALUE" ] || text_out assistant "$FIELD_VALUE" ;;
    thinking)
      event_field "$data" text
      [ -z "$FIELD_VALUE" ] || text_out thinking "$FIELD_VALUE" ;;
    tool_call) render_tool_call "$data" ;;
    status)
      event_field "$data" status
      begin_line
      printf '[status] %s\n' "$FIELD_VALUE" ;;
    result)
      event_field "$data" status
      begin_line
      printf '[result] %s\n' "$FIELD_VALUE"
      event_field "$data" text
      [ -z "$FIELD_VALUE" ] || printf '%s\n' "$FIELD_VALUE" ;;
    error)
      begin_line
      event_field "$data" message
      txt=$FIELD_VALUE
      if [ -z "$txt" ]; then
        event_field "$data" error
        txt=$FIELD_VALUE
      fi
      printf '[error] %s\n' "${txt:-the stream reported an error with no message}" ;;
    done)
      begin_line
      printf '[done] the stream reported this run complete\n' ;;
    *)
      begin_line
      printf '[%s] %s\n' "$ev" "${data//$'\n'/ }" ;;
  esac
}

# Status line and retention window out of the response headers. HTTP/2 lowercases
# header names, so the retention header is matched case-insensitively.
read_stream_headers() {
  local line lower v
  STREAM_HTTP=
  [ -s "$STREAM_HDR" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in
      HTTP/*)
        v=${line#* }
        STREAM_HTTP=${v%% *}
        continue ;;
    esac
    lower=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
    case $lower in
      x-cursor-stream-retention-seconds:*)
        v=${lower#*:}
        v=${v## }
        v=${v%% }
        case $v in
          '' | *[!0-9]*) ;;
          *) STREAM_RETENTION=$v ;;
        esac ;;
    esac
  done < "$STREAM_HDR"
}

# One connection. Reads until the stream ends, the run reports itself finished, or
# curl's own --max-time cuts it off - so this function cannot outlive its budget
# even if the far end never speaks again.
stream_attempt() {  # <max-time>
  local max=$1 line ev='' data='' eid='' chunk hdrs=()
  : > "$STREAM_HDR"
  # The event id comes from the API and goes back out in a request header, so a
  # value carrying CR or LF would be header injection into our own request.
  # Anything outside the observed shape is dropped rather than sanitized.
  if [ -n "$LAST_EVENT_ID" ]; then
    case $LAST_EVENT_ID in
      *[!A-Za-z0-9._:-]*) LAST_EVENT_ID= ;;
      *) hdrs=(-H "Last-Event-ID: $LAST_EVENT_ID") ;;
    esac
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in
      '')
        dispatch_event "$ev" "$data" "$eid"
        ev=''; data=''; eid=''
        [ "$STREAM_TERMINAL" -eq 0 ] || break ;;
      'id:'*) eid=$(sse_value "$line") ;;
      'event:'*) ev=$(sse_value "$line") ;;
      'data:'*)
        chunk=$(sse_value "$line")
        data=${data:+$data$'\n'}$chunk ;;
      ':'*) ;;
      # Anything else is an unknown SSE field or a response that is not an event
      # stream at all - a JSON error body, for instance. Ignored on purpose: the
      # status line in the headers is what says what happened.
      *) ;;
    esac
  done < <(curl --config "$SCFG" --no-buffer --max-time "$max" \
      -D "$STREAM_HDR" -H 'Accept: text/event-stream' \
      "${hdrs[@]+${hdrs[@]}}" \
      "$API_BASE/v1/agents/$WATCH_AGENT/runs/$WATCH_RUN/stream" 2>/dev/null)
  read_stream_headers
}

# The authoritative outcome, taken from the run endpoint rather than from the last
# event seen. This is the same source the watcher poll reads, which is what makes
# "the poll wins" true here instead of merely intended.
confirm_run_status() {  # -> prints "<status>\t<reason>"
  if api_try_get "/v1/agents/$WATCH_AGENT/runs/$WATCH_RUN"; then
    printf '%s\t' "$(jq -r '.status // "unknown"' "$BODY")"
  else
    printf 'unknown\t%s' "$API_ERROR"
  fi
}

cmd_watch() {
  local agent='' run='' timeout=900 attempts=3 replay=0 status='' reason=''
  while [ "$#" -gt 0 ]; do
    case $1 in
      --json) WATCH_JSON=1 ;;
      --replay) replay=1 ;;
      --run)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--run needs a run id"
        run=$2; shift ;;
      --run=*) run=${1#--run=}; [ -n "$run" ] || die 2 "--run= needs a run id" ;;
      --timeout)
        [ "$#" -ge 2 ] || die 2 "--timeout needs a value"
        valid_watch_timeout "$2" || die 2 "--timeout must be a whole number of seconds from 5 to 21600"
        timeout=$2; shift ;;
      --timeout=*)
        valid_watch_timeout "${1#--timeout=}" || die 2 "--timeout must be a whole number of seconds from 5 to 21600"
        timeout=${1#--timeout=} ;;
      --attempts)
        [ "$#" -ge 2 ] || die 2 "--attempts needs a value"
        valid_attempts "$2" || die 2 "--attempts must be a whole number from 0 to 9"
        attempts=$2; shift ;;
      --attempts=*)
        valid_attempts "${1#--attempts=}" || die 2 "--attempts must be a whole number from 0 to 9"
        attempts=${1#--attempts=} ;;
      -*) die 2 "unknown option for watch: $1" ;;
      *)
        [ -z "$agent" ] || die 2 "watch takes exactly one agent id"
        agent=$1 ;;
    esac
    shift
  done
  [ -n "$agent" ] || die 2 "watch needs an agent id (see: fm-cursor.sh list)"
  valid_agent_id "$agent" || die 2 "not a valid agent id: $agent"
  [ -z "$run" ] || valid_agent_id "$run" || die 2 "not a valid run id: $run"

  # Which run, and what state is it in. Refusing here rather than streaming blind
  # keeps a "watch" that could only ever hang from looking like a working one.
  if [ -n "$run" ]; then
    api_get "/v1/agents/$agent/runs/$run"
    status=$(jq -r '.status // "unknown"' "$BODY")
  else
    read_run_status_record "$(latest_run_status "$agent" "")"
    case $RUN_STATUS in
      none) die 5 "agent $agent has no runs to watch yet." ;;
      unknown) die 5 "cannot tell which run to watch on agent $agent: $RUN_REASON. Refusing to attach blind." ;;
    esac
    run=$RUN_ID
    status=$RUN_STATUS
  fi
  WATCH_AGENT=$agent
  WATCH_RUN=$run

  # A terminal run's stream is a full transcript replay, which is useful but is
  # not what "watch" means, so it is opt-in. The cheap answer - the final state
  # and the agent's own final text - is what an operator asking about a finished
  # run actually wants.
  case $status in
    FINISHED|ERROR|CANCELLED|EXPIRED)
      if [ "$replay" -eq 0 ]; then
        local final_text=''
        if api_try_get "/v1/agents/$agent/runs/$run"; then
          final_text=$(jq -r '.result // empty' "$BODY")
        fi
        if [ "$WATCH_JSON" -eq 1 ]; then
          jq -nc --arg a "$agent" --arg r "$run" --arg s "$status" --arg t "$final_text" '{
            schema: "fm-cursor-watch.v1", agentId: $a, runId: $r,
            streamed: false, terminal: true, runStatus: $s,
            runStatusSource: "run-detail",
            reason: "the run had already ended; pass --replay to stream its history",
            result: (if $t == "" then null else $t end)
          }'
          return 0
        fi
        printf 'Run %s on agent %s has already ended: %s.\n' "$run" "$agent" "$status"
        if [ -n "$final_text" ]; then
          printf '\nThe agent'"'"'s final text:\n\n%s\n' "$final_text"
        else
          printf 'The agent reported no final text for this run.\n'
        fi
        printf '\nNothing is streaming, because there is nothing left to watch. Pass --replay to stream this run'"'"'s full history from the beginning.\n'
        return 0
      fi ;;
  esac

  arm_stream_config "$timeout"

  local start now deadline remaining tries=0 give_up='' delay=1
  start=$(date +%s)
  deadline=$((start + timeout))

  if [ "$WATCH_JSON" -eq 0 ]; then
    printf 'Watching run %s on agent %s (currently %s), up to %ss.\n' \
      "$run" "$agent" "$status" "$timeout"
    printf 'This is a live view only: the watcher poll, not this stream, is what tells firstmate the run finished.\n'
    printf 'Ctrl-C stops watching and changes nothing about the run.\n\n'
  fi

  while :; do
    now=$(date +%s)
    remaining=$((deadline - now))
    if [ "$remaining" -le 0 ]; then
      give_up='the watch timeout expired'
      break
    fi
    stream_attempt "$remaining"
    if [ "$STREAM_TERMINAL" -eq 1 ]; then
      break
    fi
    case ${STREAM_HTTP:-} in
      410)
        give_up='the stream for this run has expired, so its events are no longer available'
        break ;;
      401|403)
        give_up="the Cursor API rejected the key for the stream (HTTP $STREAM_HTTP)"
        break ;;
      404)
        give_up='the stream endpoint reported this run as not found'
        break ;;
      429)
        give_up='the Cursor API rate limited the stream, so backing off rather than reconnecting'
        break ;;
      200|'') ;;
      *)
        give_up="the stream endpoint answered HTTP $STREAM_HTTP"
        break ;;
    esac
    # A dropped or cut-off connection. Resume from the last event rather than
    # replaying, and only while there is budget and the retention window holds.
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      give_up='the watch timeout expired'
      break
    fi
    if [ "$tries" -ge "$attempts" ]; then
      give_up="the stream dropped and the $attempts reconnection attempt(s) allowed were used"
      break
    fi
    if [ -n "$STREAM_RETENTION" ] && [ "$((now - start))" -gt "$STREAM_RETENTION" ]; then
      give_up="the stream's ${STREAM_RETENTION}s retention window has passed, so it can no longer be resumed"
      break
    fi
    tries=$((tries + 1))
    if [ "$WATCH_JSON" -eq 0 ]; then
      begin_line
      printf '[stream] connection ended before the run did; reconnecting (%s of %s)%s\n' \
        "$tries" "$attempts" "${LAST_EVENT_ID:+ from the last event seen}"
    fi
    sleep "$delay"
    [ "$delay" -ge 8 ] && delay=8 || delay=$((delay * 2))
  done

  # Confirm against the run endpoint, always. The stream is the view; this is the
  # fact - and it is also the fallback that makes an expired stream harmless.
  local confirmed
  confirmed=$(confirm_run_status)
  status=${confirmed%%$'\t'*}
  reason=${confirmed#*$'\t'}

  if [ "$WATCH_JSON" -eq 1 ]; then
    jq -nc --arg a "$agent" --arg r "$run" --arg s "$status" --arg reason "$reason" \
      --arg give_up "$give_up" --argjson ev "$STREAM_EVENTS" --argjson hb "$STREAM_HEARTBEATS" \
      --argjson tok "$STREAM_TOKENS" --argjson tries "$tries" \
      --arg ret "$STREAM_RETENTION" --arg last "$LAST_EVENT_ID" \
      --argjson terminal "$([ "$STREAM_TERMINAL" -eq 1 ] && echo true || echo false)" '{
        schema: "fm-cursor-watch.v1", agentId: $a, runId: $r,
        streamed: true,
        streamReachedEnd: $terminal,
        events: $ev, heartbeats: $hb, tokensObserved: $tok, reconnects: $tries,
        retentionSeconds: (if $ret == "" then null else ($ret | tonumber) end),
        lastEventId: (if $last == "" then null else $last end),
        stoppedBecause: (if $give_up == "" then null else $give_up end),
        runStatus: $s,
        runStatusSource: "run-detail",
        runStatusReason: (if $reason == "" then null else $reason end)
      }'
    return 0
  fi

  begin_line
  echo
  printf '%s event(s) seen' "$STREAM_EVENTS"
  [ "$STREAM_HEARTBEATS" -eq 0 ] || printf ', %s heartbeat(s)' "$STREAM_HEARTBEATS"
  [ "$STREAM_TOKENS" -eq 0 ] || printf ', %s token(s) reported' "$STREAM_TOKENS"
  [ "$tries" -eq 0 ] || printf ', %s reconnection(s)' "$tries"
  printf '.\n'
  [ -z "$STREAM_RETENTION" ] || \
    printf 'This run'"'"'s stream is retained for %ss from its start; after that only the run record remains.\n' \
      "$STREAM_RETENTION"
  if [ -n "$give_up" ]; then
    printf 'Stopped watching: %s.\n' "$give_up"
    printf 'That affects this live view only. The run itself is unaffected, and the watcher poll still reports its outcome.\n'
  fi
  if [ "$status" = unknown ]; then
    printf 'The run record could not be read to confirm the outcome: %s\n' "$reason"
  else
    printf 'Run %s is %s, from the run record rather than from the stream.\n' "$run" "$status"
  fi
}

# --- mutating verbs ---------------------------------------------------------
#
# These four act on the operator's live fleet, so each requires an explicit agent
# id. There is deliberately no "most recent" default and no wildcard: steering the
# wrong agent is not recoverable by re-running a command.

cmd_send() {
  local json=0 agent='' text=''
  while [ "$#" -gt 0 ]; do
    case $1 in
      --json) json=1 ;;
      --) shift; break ;;
      -*) die 2 "unknown option for send: $1" ;;
      *)
        if [ -z "$agent" ]; then
          agent=$1
        else
          text=${text:+$text }$1
        fi
        ;;
    esac
    shift
  done
  while [ "$#" -gt 0 ]; do
    text=${text:+$text }$1
    shift
  done
  [ -n "$agent" ] || die 2 "send needs an agent id and a prompt (see: fm-cursor.sh list)"
  valid_agent_id "$agent" || die 2 "not a valid agent id: $agent"
  [ -n "$text" ] || die 2 "send needs prompt text after the agent id"

  refuse_if_busy "$agent" send

  new_body_file
  # NOTE: `mcpServers` is deliberately ABSENT from this body and must stay absent.
  # The API documents follow-up definitions as REPLACING the agent's create-time
  # inline MCP servers for that run, so sending any list here silently strips
  # every server not in it and the agent loses tools mid-conversation with no
  # error. Omitting the field is the correct default, not an oversight.
  jq -n --arg t "$text" '{prompt: {text: $t}}' > "$REQ" \
    || die 3 "could not build the request body"

  if ! api_try_post "/v1/agents/$agent/runs" "$REQ"; then
    if [ "${API_HTTP_CODE:-}" = 409 ]; then
      die 5 "agent $agent became busy between the check and the send: $API_ERROR. Nothing was sent; retry once its run finishes."
    fi
    die 4 "$API_ERROR"
  fi

  if [ "$json" -eq 1 ]; then
    jq --arg a "$agent" '{schema: "fm-cursor-send.v1", agentId: $a, run: .}' "$BODY"
    return 0
  fi
  printf 'Sent a follow-up to %s.\n' "$agent"
  printf '  run    %s\n' "$(jq -r '(.id // .run.id) // "-"' "$BODY")"
  printf '  status %s\n' "$(jq -r '(.status // .run.status) // "-"' "$BODY")"
  echo 'The run is now the agent'"'"'s active one; watch it with runs, and no further follow-up can be sent until it finishes.'
}

cmd_cancel() {
  local json=0 agent=''
  while [ "$#" -gt 0 ]; do
    case $1 in
      --json) json=1 ;;
      -*) die 2 "unknown option for cancel: $1" ;;
      *)
        [ -z "$agent" ] || die 2 "cancel takes exactly one agent id"
        agent=$1
        ;;
    esac
    shift
  done
  [ -n "$agent" ] || die 2 "cancel needs an agent id (see: fm-cursor.sh list)"
  valid_agent_id "$agent" || die 2 "not a valid agent id: $agent"

  read_run_status_record "$(latest_run_status "$agent" "")"
  case $RUN_STATUS in
    RUNNING|CREATING) ;;
    unknown) die 5 "cannot tell what agent $agent is doing: $RUN_REASON. Refusing to cancel blind." ;;
    none) die 5 "agent $agent has no runs to cancel." ;;
    *) die 5 "agent $agent has nothing to cancel: its latest run ${RUN_ID} is already $RUN_STATUS." ;;
  esac

  if ! api_try_post "/v1/agents/$agent/runs/$RUN_ID/cancel"; then
    die 4 "$API_ERROR"
  fi
  if [ "$json" -eq 1 ]; then
    jq -n --arg a "$agent" --arg r "$RUN_ID" \
      '{schema: "fm-cursor-cancel.v1", agentId: $a, runId: $r, cancelled: true}'
    return 0
  fi
  printf 'Cancelled run %s on agent %s.\n' "$RUN_ID" "$agent"
  echo 'Work the run had already pushed stays on its branch; cancelling stops the run, it does not undo commits.'
}

# archive/unarchive are the reversible lifecycle pair, and the only cleanup this
# helper offers. DELETE /v1/agents/{id} is deliberately NOT wired: it is permanent
# and nothing here needs it.
cmd_archive() {
  archive_verb archive "$@"
}

cmd_unarchive() {
  archive_verb unarchive "$@"
}

archive_verb() {  # <archive|unarchive> <args...>
  local verb=$1 json=0 agent=''
  shift
  while [ "$#" -gt 0 ]; do
    case $1 in
      --json) json=1 ;;
      -*) die 2 "unknown option for $verb: $1" ;;
      *)
        [ -z "$agent" ] || die 2 "$verb takes exactly one agent id"
        agent=$1
        ;;
    esac
    shift
  done
  [ -n "$agent" ] || die 2 "$verb needs an agent id (see: fm-cursor.sh list)"
  valid_agent_id "$agent" || die 2 "not a valid agent id: $agent"

  if [ "$verb" = archive ]; then
    refuse_if_busy "$agent" archive
  fi

  if ! api_try_post "/v1/agents/$agent/$verb"; then
    die 4 "$API_ERROR"
  fi
  if [ "$json" -eq 1 ]; then
    jq -n --arg a "$agent" --arg v "$verb" \
      '{schema: "fm-cursor-archive.v1", agentId: $a, action: $v, ok: true}'
    return 0
  fi
  if [ "$verb" = archive ]; then
    printf 'Archived agent %s. This is reversible: unarchive brings it back.\n' "$agent"
  else
    printf 'Unarchived agent %s.\n' "$agent"
  fi
}

cmd_create() {
  local json=0 env_name='' prompt='' prompt_file='' model='' current_branch=0
  while [ "$#" -gt 0 ]; do
    case $1 in
      --json) json=1 ;;
      --work-on-current-branch) current_branch=1 ;;
      --env)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--env needs an environment name"
        env_name=$2; shift ;;
      --env=*) env_name=${1#--env=}; [ -n "$env_name" ] || die 2 "--env= needs a name" ;;
      --prompt)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--prompt needs text"
        prompt=$2; shift ;;
      --prompt=*) prompt=${1#--prompt=} ;;
      --prompt-file)
        [ "$#" -ge 2 ] || die 2 "--prompt-file needs a path"
        prompt_file=$2; shift ;;
      --prompt-file=*) prompt_file=${1#--prompt-file=} ;;
      --model)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "--model needs a model id"
        model=$2; shift ;;
      --model=*) model=${1#--model=} ;;
      *) die 2 "unknown option for create: $1" ;;
    esac
    shift
  done

  [ -z "$prompt" ] || [ -z "$prompt_file" ] || die 2 "pass either --prompt or --prompt-file, not both"
  if [ -n "$prompt_file" ]; then
    [ -f "$prompt_file" ] || die 2 "no such prompt file: $prompt_file"
    prompt=$(cat "$prompt_file") || die 2 "could not read prompt file: $prompt_file"
  fi
  [ -n "$prompt" ] || die 2 "create needs --prompt <text> or --prompt-file <path>"

  # The environment is the unit of work, so it defaults to this home's configured
  # one rather than making the operator repeat it.
  if [ -z "$env_name" ]; then
    env_name=$(default_environment)
    [ -n "$env_name" ] || die 2 "create needs --env <name>, or a default in $CONFIG/cursor-environment"
  fi

  # Validate the model against what the account actually offers rather than a
  # hardcoded list, which would rot as Cursor's catalog changes.
  if [ -n "$model" ]; then
    api_get "/v1/models"
    if ! jq -e --arg m "$model" '[(.models // .items // [])[]
          | if type == "object" then .id else . end] | index($m) != null' "$BODY" >/dev/null; then
      die 2 "model '$model' is not in this account's catalog. Available: $(jq -r '[(.models // .items // [])[] | if type == "object" then .id else . end] | join(", ")' "$BODY")"
    fi
  fi

  new_body_file
  # `env` names the environment and `repos` is deliberately never sent: the API
  # documents them as mutually exclusive, and the environment is what carries the
  # predefined secrets and MCP configuration. Enumerating an environment's
  # repositories instead would produce an agent that looks right and cannot
  # authenticate.
  # workOnCurrentBranch is accepted alongside a NAMED environment, verified
  # against the live API on 2026-08-01: the commit lands on whatever branch the
  # agent checks out rather than on a generated `cursor/...` branch, so an
  # environment's secrets and branch control are not an either/or choice.
  jq -n --arg t "$prompt" --arg e "$env_name" --arg m "$model" \
    --argjson cur "$([ "$current_branch" -eq 1 ] && echo true || echo false)" '
      {prompt: {text: $t}, env: {type: "cloud", name: $e}}
      + (if $m == "" then {} else {model: {id: $m}} end)
      + (if $cur then {workOnCurrentBranch: true} else {} end)' > "$REQ" \
    || die 3 "could not build the request body"

  api_try_post "/v1/agents" "$REQ" || die 4 "$API_ERROR"

  if [ "$json" -eq 1 ]; then
    jq --arg e "$env_name" '{schema: "fm-cursor-create.v1", environment: $e} + .' "$BODY"
    return 0
  fi
  local id url
  id=$(jq -r '(.agent.id // .id) // "-"' "$BODY")
  url=$(jq -r '(.agent.url // .url) // "-"' "$BODY")
  printf 'Created agent %s in environment %s.\n' "$id" "$env_name"
  printf '  run    %s\n' "$(jq -r '(.run.id // .latestRunId) // "-"' "$BODY")"
  printf '  status %s\n' "$(jq -r '(.run.status // .agent.status // .status) // "-"' "$BODY")"
  printf '  url    %s\n' "$url"
  echo 'Open the url to watch it in Cursor Web; steer it with send, and archive it when it is no longer wanted.'
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
SUB=$1
shift
case $SUB in
  -h|--help|help) usage; exit 0 ;;
  list|show|runs|usage|watch|send|cancel|archive|unarchive|create) ;;
  *) die 2 "unknown subcommand: $SUB (expected list, show, runs, usage, watch, send, cancel, archive, unarchive, or create)" ;;
esac

require_tools
arm_auth
"cmd_$SUB" "$@"
