#!/usr/bin/env bash
# Behavior tests for bin/fm-cursor.sh - the read-only Cursor Cloud agent view.
#
# Hermetic: a fake `curl` on PATH answers every request from canned fixtures, so
# no test here reaches api.cursor.com and none needs a real API key. The fake is
# also the credential assertion - it inspects its own argv and the curl config
# file it was handed, so "the key never reaches a process argument" is proven by
# the same mechanism that serves the responses rather than by reading the source.
#
# Cases:
#   (a) absent key                     -> exit 3, actionable message, no request
#   (b) key with unsafe characters     -> exit 3, refused before any request
#   (c) ambient CURSOR_API_KEY ignored -> .env is the only source
#   (d) usage errors                   -> exit 2 (no subcommand, unknown sub/opt,
#                                        missing id, bad id, out-of-range limit)
#   (e) the key never appears in curl's argv, and its config file is mode 0600
#   (f) list reports LATEST RUN status, not the ACTIVE|ARCHIVED lifecycle field
#   (g) latestRunId is the fast path; a missing one falls back to the runs list
#   (h) --no-runs resolves nothing and says so
#   (i) the ENVIRONMENT is the agent's identity: a named environment is surfaced,
#       an agent built from a bare repo list shows as ad-hoc, and a multi-repo
#       agent reports its repository count rather than reading as single-repo
#   (j) --json emits the documented schema names and summary counts
#   (k) archived agents are hidden by default and included with --all
#   (l) HTTP failures report the API's message, never the raw body
#   (m) a temp key/response file never survives the run
#   (n) config/cursor-environment: absent means no default; present marks the
#       default in list WITHOUT filtering it away; --env filters, a bare --env
#       uses the default, and filtering happens before run resolution
#   (o) an --env that matches nothing still reports the fetched count and the
#       --limit caveat, so an empty view never reads as an empty fleet
#   (p) a run request that fails degrades only that run to an unknown status,
#       carrying the reason so a 429 never reads like a 404 or a rejected key:
#       list keeps every other row, show still renders the agent it fetched, and
#       only a top-level fetch still exits 4. The ad-hoc environment label is
#       asserted through show as well as list, since each has its own renderer
#   (q) FM_CURSOR_ENV_FILE takes precedence over $FM_HOME/.env
#   (r) FM_CURSOR_TIMEOUT is validated before it reaches curl's config file
#   (s) mutating verbs: send/archive refuse a busy agent and an indeterminate run
#       state before issuing any request, a 409 race is a clean refusal, cancel
#       targets only a genuinely active run, archive/unarchive are wired while
#       delete deliberately is not, and none accepts a missing or wildcard id
#   (t) a follow-up run NEVER carries mcpServers, because the API replaces the
#       agent's create-time set and would strip its tools mid-conversation
#   (u) create NAMES the environment and never enumerates repos, defaults the
#       environment from config/cursor-environment, validates --model against the
#       live catalog, and prints the new agent's url
#   (v) the --no-runs footer never asserts an in-flight count
#   (w) an API-supplied agent name carrying the record separator, a newline or a
#       tab cannot split or truncate its table row
#   (x) runs --json hydrates the `result` the LIST endpoint omits, from the
#       individual run, and only for a run that can already have one; --no-result
#       skips it, and a failed hydration degrades that one run with its reason
#   (y) watch renders a live run as prose, counts heartbeats without ever printing
#       them as content, ignores the duplicate interaction_update delta channel,
#       and confirms the outcome against the run record rather than the stream
#   (z) a mid-stream disconnect resumes with Last-Event-ID from the last event
#       seen rather than replaying, within a bounded attempt budget
#   (aa) 410 stream_expired falls back to the run record, a 429 backs off, and
#       neither fails the command nor leaks the non-SSE error body as content
#   (bb) watch --json emits one parseable object per event, heartbeats included,
#       then one summary object carrying the poll-confirmed run state
#   (cc) a run that has already ended is reported with its final text rather than
#       replayed, unless --replay asks for the history
#   (dd) watch refuses rather than attaching blind: no runs, or a run state that
#       could not be determined
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CURSOR="$ROOT/bin/fm-cursor.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

# A key shaped like a real one: URL-safe base64, no characters the config-file
# writer would have to escape.
KEY=key_0123456789abcdefABCDEF-_
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR"
printf 'CURSOR_API_KEY=%s\n' "$KEY" > "$HOME_DIR/.env"

FIXTURES="$TMP_ROOT/fixtures"
mkdir -p "$FIXTURES"

# --- fake curl ---------------------------------------------------------------
#
# Serves $FIXTURES/<slug>.json for a request path, where <slug> is the path with
# non-alphanumerics folded to '_'. Writes the HTTP code configured in
# $FIXTURES/<slug>.code (default 200) to stdout, exactly as the real
# `curl -w '%{http_code}'` does. Records every invocation for later assertions.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
# Snapshot argv BEFORE parsing: the parse loop below consumes "$@", so the
# credential check has to inspect a copy or it silently inspects nothing.
ARGV=("$0" "$@")
out=
url=
cfg=
method=GET
data=
dump=
want_code=0
resume=
while [ "$#" -gt 0 ]; do
  case $1 in
    --config) cfg=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    -w) want_code=1; shift 2 ;;
    -X) method=$2; shift 2 ;;
    -D) dump=$2; shift 2 ;;
    -H)
      # A stream resume carries the last event id in a request header, and the
      # test needs to see whether it was sent and with what value.
      case $2 in
        Last-Event-ID:*) resume=${2#Last-Event-ID: } ;;
      esac
      shift 2 ;;
    --data-binary) data=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
: >> "$FM_CURSOR_TEST_CALLS"
printf '%s %s\n' "$method" "$url" >> "$FM_CURSOR_TEST_CALLS"
# Record the request body so a test can assert what was and was not sent -
# notably that a follow-up never carries mcpServers and a create never carries
# repos.
if [ -n "$data" ] && [ -n "${FM_CURSOR_TEST_BODIES:-}" ]; then
  case $data in
    @*) cat "${data#@}" >> "$FM_CURSOR_TEST_BODIES" 2>/dev/null || true ;;
    *) printf '%s' "$data" >> "$FM_CURSOR_TEST_BODIES" ;;
  esac
  printf '\n' >> "$FM_CURSOR_TEST_BODIES"
fi
# Credential guarantees, asserted at the moment of use.
if [ -n "${FM_CURSOR_TEST_KEY:-}" ]; then
  for a in "${ARGV[@]}"; do
    case $a in
      *"$FM_CURSOR_TEST_KEY"*) printf 'KEY_IN_ARGV\n' >> "$FM_CURSOR_TEST_VIOLATIONS" ;;
    esac
  done
fi
if [ -n "$cfg" ]; then
  if [ "$(uname)" = Darwin ]; then
    perms=$(stat -f '%Lp' "$cfg" 2>/dev/null || echo unknown)
  else
    perms=$(stat -c '%a' "$cfg" 2>/dev/null || echo unknown)
  fi
  [ "$perms" = 600 ] || printf 'CFG_PERMS=%s\n' "$perms" >> "$FM_CURSOR_TEST_VIOLATIONS"
  grep -q "Authorization: Bearer ${FM_CURSOR_TEST_KEY}" "$cfg" \
    || printf 'CFG_MISSING_HEADER\n' >> "$FM_CURSOR_TEST_VIOLATIONS"
  printf '%s\n' "$cfg" >> "$FM_CURSOR_TEST_CFGS"
fi
slug=$(printf '%s' "${url#*://}" | sed 's/[^A-Za-z0-9]/_/g')
# An event-stream request is answered on STDOUT rather than through -o, exactly
# as the real curl streams it, with the status line and retention header written
# to the -D file. `<slug>.sse` is the first connection and `<slug>.resume.sse`
# the reconnection, so a test can prove a resume continued instead of restarting.
case $url in
  */stream)
    printf '%s %s\n' "$method" "$url" >> "$FM_CURSOR_TEST_RESUMES"
    [ -z "$resume" ] || printf 'RESUME %s\n' "$resume" >> "$FM_CURSOR_TEST_RESUMES"
    scode=200
    [ ! -f "$FM_CURSOR_TEST_FIXTURES/$slug.stream-code" ] \
      || scode=$(cat "$FM_CURSOR_TEST_FIXTURES/$slug.stream-code")
    if [ -n "$dump" ]; then
      printf 'HTTP/2 %s \r\n' "$scode" > "$dump"
      if [ -f "$FM_CURSOR_TEST_FIXTURES/$slug.retention" ]; then
        printf 'x-cursor-stream-retention-seconds: %s\r\n' \
          "$(cat "$FM_CURSOR_TEST_FIXTURES/$slug.retention")" >> "$dump"
      fi
      printf '\r\n' >> "$dump"
    fi
    body="$FM_CURSOR_TEST_FIXTURES/$slug.sse"
    [ -z "$resume" ] || body="$FM_CURSOR_TEST_FIXTURES/$slug.resume.sse"
    [ ! -f "$body" ] || cat "$body"
    exit 0 ;;
esac
# A method-qualified fixture wins, so a POST and a GET on the same path can be
# answered differently; an unqualified fixture still serves both.
body="$FM_CURSOR_TEST_FIXTURES/${method}_$slug.json"
code_file="$FM_CURSOR_TEST_FIXTURES/${method}_$slug.code"
[ -f "$body" ] || body="$FM_CURSOR_TEST_FIXTURES/$slug.json"
[ -f "$code_file" ] || code_file="$FM_CURSOR_TEST_FIXTURES/$slug.code"
code=200
[ ! -f "$code_file" ] || code=$(cat "$code_file")
if [ -f "$body" ]; then
  [ -z "$out" ] || cp "$body" "$out"
else
  [ -z "$out" ] || printf '{"message":"no fixture for %s"}' "$slug" > "$out"
  code=404
fi
# Only when -w asked for it, so a request reading its body from stdout never gets
# a status code mixed into that body.
[ "$want_code" -eq 0 ] || printf '%s' "$code"
SH
chmod +x "$FAKEBIN/curl"

export FM_CURSOR_TEST_FIXTURES="$FIXTURES"
export FM_CURSOR_TEST_KEY="$KEY"
CALLS="$TMP_ROOT/calls"
VIOLATIONS="$TMP_ROOT/violations"
CFGS="$TMP_ROOT/cfgs"
RESUMES="$TMP_ROOT/resumes"
export FM_CURSOR_TEST_CALLS="$CALLS" FM_CURSOR_TEST_VIOLATIONS="$VIOLATIONS" FM_CURSOR_TEST_CFGS="$CFGS"
export FM_CURSOR_TEST_RESUMES="$RESUMES"

fixture() {  # <url-path> <json>
  local slug
  slug=$(printf '%s' "api.cursor.com$1" | sed 's/[^A-Za-z0-9]/_/g')
  printf '%s' "$2" > "$FIXTURES/$slug.json"
}

fixture_code() {  # <url-path> <http-code>
  local slug
  slug=$(printf '%s' "api.cursor.com$1" | sed 's/[^A-Za-z0-9]/_/g')
  printf '%s' "$2" > "$FIXTURES/$slug.code"
}

# Method-qualified variants, so a POST and a GET on the same path can be answered
# differently. The fake curl prefers <METHOD>_<slug> over the bare slug.
fixture_post() {  # <url-path> <json>
  local slug
  slug=$(printf '%s' "api.cursor.com$1" | sed 's/[^A-Za-z0-9]/_/g')
  printf '%s' "$2" > "$FIXTURES/POST_$slug.json"
}

fixture_post_code() {  # <url-path> <http-code>
  local slug
  slug=$(printf '%s' "api.cursor.com$1" | sed 's/[^A-Za-z0-9]/_/g')
  printf '%s' "$2" > "$FIXTURES/POST_$slug.code"
}

# run_cursor <args...>: run the helper with the fake curl and the fixture home,
# leaving combined output in $OUT and the exit status in $RC.
#
# Deliberately NOT `out=$(run_cursor ...)`: assigning RC inside a command
# substitution sets it in the subshell only, so the caller would read a stale
# status from an earlier call and every exit-code assertion would silently pass.
RC=0
OUT=
CONFIG_DIR="$TMP_ROOT/config"
mkdir -p "$CONFIG_DIR"

run_cursor() {
  : > "$CALLS"
  : > "$VIOLATIONS"
  : > "$CFGS"
  : > "$RESUMES"
  set +e
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$CONFIG_DIR" \
    FM_CURSOR_API_BASE="https://api.cursor.com" "$CURSOR" "$@" 2>&1)
  RC=$?
  set -e
}

# run_cursor with extra environment assignments, for the cases that are ABOUT the
# environment rather than the arguments. The later `env` assignments win, so a
# case can override FM_HOME or supply a value the shell could not pass inline.
run_cursor_env() {  # <VAR=VALUE>... -- <args>...
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  [ "$#" -eq 0 ] || shift
  : > "$CALLS"
  : > "$VIOLATIONS"
  : > "$CFGS"
  : > "$RESUMES"
  set +e
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$CONFIG_DIR" \
    FM_CURSOR_API_BASE="https://api.cursor.com" env "${envs[@]}" "$CURSOR" "$@" 2>&1)
  RC=$?
  set -e
}

# --- fixtures ----------------------------------------------------------------

AGENT_MULTI=bc-1111aaaa
AGENT_SINGLE=bc-2222bbbb
AGENT_NORUNID=bc-3333cccc
AGENT_ARCHIVED=bc-4444dddd
AGENT_STALERUN=bc-5555eeee
AGENT_STALERUN_SHOW=bc-6666ffff
AGENT_ADHOC_SHOW=bc-7777gggg
AGENT_THROTTLED=bc-8888hhhh

fixture "/v1/agents?limit=20&includeArchived=false" '{"items":[
  {"id":"bc-1111aaaa","name":"Severity sorting","status":"ACTIVE","latestRunId":"run-aaa1",
   "createdAt":"2026-07-30T14:57:06.760Z","updatedAt":"2026-07-31T11:44:22.735Z",
   "url":"https://cursor.com/agents/bc-1111aaaa","env":{"type":"cloud","name":"AgentScan E2E"},
   "repos":[{"url":"https://github.com/snyk/invariant-mcp-scan-backend"},
            {"url":"https://github.com/snyk/agent-scan"},
            {"url":"https://github.com/snyk/maverick"},
            {"url":"https://github.com/snyk/maverick-ui"}]},
  {"id":"bc-2222bbbb","name":"Single repo work","status":"ACTIVE","latestRunId":"run-bbb1",
   "createdAt":"2026-07-29T09:00:00.000Z","updatedAt":"2026-07-29T10:00:00.000Z",
   "url":"https://cursor.com/agents/bc-2222bbbb","env":{"type":"cloud"},
   "repos":[{"url":"https://github.com/snyk/minired"}]},
  {"id":"bc-3333cccc","name":"No latest run id","status":"ACTIVE",
   "createdAt":"2026-07-28T09:00:00.000Z","updatedAt":"2026-07-28T10:00:00.000Z",
   "url":"https://cursor.com/agents/bc-3333cccc","env":{"type":"cloud"},
   "repos":[{"url":"https://github.com/snyk/prompt-siren"}]}
]}'

fixture "/v1/agents?limit=20&includeArchived=true" '{"items":[
  {"id":"bc-1111aaaa","name":"Severity sorting","status":"ACTIVE","latestRunId":"run-aaa1",
   "createdAt":"2026-07-30T14:57:06.760Z","updatedAt":"2026-07-31T11:44:22.735Z",
   "url":"https://cursor.com/agents/bc-1111aaaa","env":{"type":"cloud"},
   "repos":[{"url":"https://github.com/snyk/invariant-mcp-scan-backend"},
            {"url":"https://github.com/snyk/agent-scan"}]},
  {"id":"bc-4444dddd","name":"Old archived thing","status":"ARCHIVED","latestRunId":"run-ddd1",
   "createdAt":"2026-06-01T09:00:00.000Z","updatedAt":"2026-06-02T10:00:00.000Z",
   "url":"https://cursor.com/agents/bc-4444dddd","env":{"type":"cloud"},
   "repos":[{"url":"https://github.com/snyk/minired"}]}
]}'

# A RUNNING latest run on an ACTIVE agent, and a FINISHED one on another ACTIVE
# agent: the pair that proves lifecycle and execution are independent.
fixture "/v1/agents/$AGENT_MULTI/runs/run-aaa1" \
  '{"id":"run-aaa1","agentId":"bc-1111aaaa","status":"RUNNING","createdAt":"2026-07-31T11:09:10.326Z","durationMs":null,"git":{"branches":[]}}'
fixture "/v1/agents/$AGENT_SINGLE/runs/run-bbb1" \
  '{"id":"run-bbb1","agentId":"bc-2222bbbb","status":"FINISHED","createdAt":"2026-07-29T09:10:00.000Z","durationMs":79396,"git":{"branches":[{"repoUrl":"github.com/snyk/minired","branch":"cursor/x","prUrl":"https://github.com/snyk/minired/pull/94"}]}}'
fixture "/v1/agents/$AGENT_ARCHIVED/runs/run-ddd1" \
  '{"id":"run-ddd1","agentId":"bc-4444dddd","status":"FINISHED","createdAt":"2026-06-01T09:10:00.000Z","durationMs":1000,"git":{"branches":[]}}'
# The fallback path: this agent had no latestRunId in the list payload.
fixture "/v1/agents/$AGENT_NORUNID/runs?limit=1" \
  '{"items":[{"id":"run-ccc9","status":"ERROR","createdAt":"2026-07-28T09:10:00.000Z","durationMs":4200,"git":{"branches":[]}}]}'

# A page whose second agent points at a run that no longer resolves: latestRunId
# is not in Cursor's published schema, so a stale pointer is an expected shape.
# NEITHER of its run requests has a fixture, so the fake curl answers both with
# 404 and this page exercises a completely failed resolution.
fixture "/v1/agents?limit=5&includeArchived=false" '{"items":[
  {"id":"bc-1111aaaa","name":"Severity sorting","status":"ACTIVE","latestRunId":"run-aaa1",
   "createdAt":"2026-07-30T14:57:06.760Z","updatedAt":"2026-07-31T11:44:22.735Z",
   "url":"https://cursor.com/agents/bc-1111aaaa","env":{"type":"cloud","name":"AgentScan E2E"},
   "repos":[{"url":"https://github.com/snyk/agent-scan"}]},
  {"id":"bc-5555eeee","name":"Stale run pointer","status":"ACTIVE","latestRunId":"run-gone",
   "createdAt":"2026-07-27T09:00:00.000Z","updatedAt":"2026-07-27T10:00:00.000Z",
   "url":"https://cursor.com/agents/bc-5555eeee","env":{"type":"cloud","name":"AgentScan E2E"},
   "repos":[{"url":"https://github.com/snyk/minired"}]}
]}'
# The same stale pointer through show, where the agent's OWN fetch succeeds: the
# run alone is unresolvable, so show must render the agent and report unknown.
fixture "/v1/agents/$AGENT_STALERUN_SHOW" \
  '{"id":"bc-6666ffff","name":"Stale run pointer","status":"ACTIVE","latestRunId":"run-gone2","createdAt":"2026-07-27T09:00:00.000Z","updatedAt":"2026-07-27T10:00:00.000Z","url":"https://cursor.com/agents/bc-6666ffff","env":{"type":"cloud","name":"AgentScan E2E"},"repos":[{"url":"https://github.com/snyk/minired"}]}'

# An agent built from a bare repo list, for the show side of the ad-hoc label.
fixture "/v1/agents/$AGENT_ADHOC_SHOW" \
  '{"id":"bc-7777gggg","name":"Ad-hoc repo list","status":"ACTIVE","latestRunId":"run-ggg1","createdAt":"2026-07-26T09:00:00.000Z","updatedAt":"2026-07-26T10:00:00.000Z","url":"https://cursor.com/agents/bc-7777gggg","env":{"type":"cloud"},"repos":[{"url":"https://github.com/snyk/minired"}]}'
fixture "/v1/agents/$AGENT_ADHOC_SHOW/runs/run-ggg1" \
  '{"id":"run-ggg1","agentId":"bc-7777gggg","status":"FINISHED","createdAt":"2026-07-26T09:10:00.000Z","durationMs":1000,"git":{"branches":[]}}'

# A page whose only agent is throttled on BOTH run requests. A 429 and a 404 must
# never produce the same output, because the operator's next move differs.
fixture "/v1/agents?limit=6&includeArchived=false" '{"items":[
  {"id":"bc-8888hhhh","name":"Throttled resolution","status":"ACTIVE","latestRunId":"run-throttled",
   "createdAt":"2026-07-25T09:00:00.000Z","updatedAt":"2026-07-25T10:00:00.000Z",
   "url":"https://cursor.com/agents/bc-8888hhhh","env":{"type":"cloud","name":"AgentScan E2E"},
   "repos":[{"url":"https://github.com/snyk/minired"}]}
]}'
fixture "/v1/agents/$AGENT_THROTTLED/runs/run-throttled" '{"code":"error","message":"Too Many Requests"}'
fixture_code "/v1/agents/$AGENT_THROTTLED/runs/run-throttled" 429
fixture "/v1/agents/$AGENT_THROTTLED/runs?limit=1" '{"code":"error","message":"Too Many Requests"}'
fixture_code "/v1/agents/$AGENT_THROTTLED/runs?limit=1" 429

fixture "/v1/agents/$AGENT_SINGLE" \
  '{"id":"bc-2222bbbb","name":"Single repo work","status":"ACTIVE","latestRunId":"run-bbb1","createdAt":"2026-07-29T09:00:00.000Z","updatedAt":"2026-07-29T10:00:00.000Z","url":"https://cursor.com/agents/bc-2222bbbb","env":{"type":"cloud","name":"prod"},"repos":[{"url":"https://github.com/snyk/minired"}]}'
fixture "/v1/agents/$AGENT_SINGLE/runs?limit=20" \
  '{"items":[{"id":"run-bbb1","status":"FINISHED","createdAt":"2026-07-29T09:10:00.000Z","durationMs":135000,"git":{"branches":[{"repoUrl":"github.com/snyk/minired","branch":"cursor/x","prUrl":"https://github.com/snyk/minired/pull/94"}]}},{"id":"run-bbb0","status":"CANCELLED","createdAt":"2026-07-29T09:05:00.000Z","durationMs":30000,"git":{"branches":[]}}]}'
fixture "/v1/agents/$AGENT_SINGLE/usage" \
  '{"totalUsage":{"inputTokens":465689,"outputTokens":126637,"cacheWriteTokens":982426,"cacheReadTokens":45216792,"totalTokens":46791544},"runs":[{"id":"run-bbb1","usage":{"inputTokens":465689,"outputTokens":126637,"cacheWriteTokens":982426,"cacheReadTokens":45216792,"totalTokens":46791544}}]}'

# --- (a) absent key ----------------------------------------------------------

NOKEY_HOME="$TMP_ROOT/nokey"
mkdir -p "$NOKEY_HOME"
set +e
OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$NOKEY_HOME" "$CURSOR" list 2>&1)
RC=$?
set -e
expect_code 3 "$RC" "absent key exits 3"
assert_contains "$OUT" "not configured" "absent key names the condition"
assert_contains "$OUT" "CURSOR_API_KEY" "absent key names the variable"
assert_contains "$OUT" "$NOKEY_HOME/.env" "absent key names the file to edit"
pass "absent CURSOR_API_KEY is inert and actionable, not a confusing auth error"

# --- (b) unsafe key ----------------------------------------------------------

BADKEY_HOME="$TMP_ROOT/badkey"
mkdir -p "$BADKEY_HOME"
printf 'CURSOR_API_KEY="key with spaces and \\"quotes\\""\n' > "$BADKEY_HOME/.env"
: > "$CALLS"
set +e
OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$BADKEY_HOME" "$CURSOR" list 2>&1)
RC=$?
set -e
expect_code 3 "$RC" "unsafe key exits 3"
assert_contains "$OUT" "unexpected characters" "unsafe key is reported as malformed"
assert_not_contains "$OUT" "key with spaces" "the rejected key is never echoed back"
[ ! -s "$CALLS" ] || fail "unsafe key must be refused before any API request"
pass "a key that would break config quoting is refused before any request"

# --- (c) ambient environment key is ignored ----------------------------------

set +e
OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$NOKEY_HOME" CURSOR_API_KEY=ambient-key-value \
  "$CURSOR" list 2>&1)
RC=$?
set -e
expect_code 3 "$RC" "an ambient CURSOR_API_KEY must not activate the helper"
assert_contains "$OUT" "not configured" "ambient key is ignored in favour of .env"
pass "the key comes from .env only, never from the ambient environment"

# --- (d) usage errors --------------------------------------------------------

run_cursor; expect_code 2 "$RC" "no subcommand exits 2"
run_cursor frobnicate; expect_code 2 "$RC" "unknown subcommand exits 2"
assert_contains "$OUT" "unknown subcommand" "unknown subcommand is named"
run_cursor list --bogus; expect_code 2 "$RC" "unknown list option exits 2"
run_cursor show; expect_code 2 "$RC" "show without an id exits 2"
assert_contains "$OUT" "needs an agent id" "show explains the missing id"
run_cursor show 'bc-../../etc/passwd'; expect_code 2 "$RC" "a path-y agent id is refused"
assert_contains "$OUT" "not a valid agent id" "bad id is named as invalid"
run_cursor list --limit 0; expect_code 2 "$RC" "limit below range exits 2"
run_cursor list --limit 101; expect_code 2 "$RC" "limit above range exits 2"
run_cursor list --limit abc; expect_code 2 "$RC" "non-numeric limit exits 2"
run_cursor runs "$AGENT_SINGLE" "$AGENT_MULTI"; expect_code 2 "$RC" "two ids are refused"
pass "usage errors exit 2 with a message that names the problem"

# --- (e)(f)(g)(i) list -------------------------------------------------------

run_cursor list
expect_code 0 "$RC" "list succeeds"
[ ! -s "$VIOLATIONS" ] || fail "credential violations recorded: $(cat "$VIOLATIONS")"
pass "the key never reaches curl's argv and its config file is mode 0600"

assert_contains "$OUT" "RUNNING" "list surfaces the RUNNING latest run"
assert_contains "$OUT" "FINISHED" "list surfaces the FINISHED latest run"
assert_contains "$OUT" "ERROR" "list surfaces the fallback-resolved ERROR run"
assert_not_contains "$OUT" "ACTIVE" "the lifecycle enum is not presented as execution status"
pass "list reports latest RUN status, so ACTIVE is never mistaken for running"

grep -q "/v1/agents/$AGENT_MULTI/runs/run-aaa1" "$CALLS" \
  || fail "latestRunId should be the fast path for an agent that has one"
grep -q "/v1/agents/$AGENT_NORUNID/runs?limit=1" "$CALLS" \
  || fail "an agent with no latestRunId should fall back to the runs list"
assert_no_grep "/v1/agents/$AGENT_MULTI/runs?limit=1" "$CALLS" \
  "the fallback must not fire when latestRunId is present"
pass "latestRunId is preferred and its absence falls back to the runs list"

assert_contains "$OUT" "AgentScan E2E" "the named environment is surfaced in list"
assert_contains "$OUT" "ENVIRONMENT" "list leads with an ENVIRONMENT column"
assert_contains "$OUT" "(ad-hoc cloud)" "an agent with no named environment shows as ad-hoc"
assert_contains "$OUT" "named environment(s)" "the footer counts named environments"
assert_contains "$OUT" "not to any single repository" "list states that an agent belongs to its environment"
# The four-repo agent must report 4, so a multi-repo agent can never read as
# single-repo. Its row is the one carrying the named environment.
printf '%s\n' "$OUT" | grep -E "AgentScan E2E +4 " >/dev/null \
  || fail "the four-repo agent must report its repository count next to its environment"
pass "the environment is the unit of work and a multi-repo agent reports its repo count"

# --- (h) --no-runs -----------------------------------------------------------

run_cursor list --no-runs
expect_code 0 "$RC" "list --no-runs succeeds"
assert_contains "$OUT" "unresolved" "--no-runs marks run status unresolved"
assert_contains "$OUT" "was not resolved" "--no-runs says nothing claims to know what is running"
assert_no_grep "/runs/run-aaa1" "$CALLS" "--no-runs must issue no per-agent run request"
pass "--no-runs costs one request and admits it knows nothing about execution"

# --- (j) --json --------------------------------------------------------------

run_cursor list --json
expect_code 0 "$RC" "list --json succeeds"
printf '%s' "$OUT" | jq -e '.schema == "fm-cursor-list.v1"' >/dev/null \
  || fail "list --json must carry schema fm-cursor-list.v1"
printf '%s' "$OUT" | jq -e '.count == 3 and .summary.running == 1 and .summary.multiRepo == 1' >/dev/null \
  || fail "list --json summary counts are wrong: $(printf '%s' "$OUT" | jq -c .summary)"
printf '%s' "$OUT" | jq -e '.summary.byRunStatus.RUNNING == 1 and .summary.byRunStatus.ERROR == 1' >/dev/null \
  || fail "list --json byRunStatus is wrong"
printf '%s' "$OUT" | jq -e '[.agents[] | .runStatusSource] | contains(["latestRunId"]) and contains(["runs-list"])' >/dev/null \
  || fail "list --json must record which source answered per agent"
printf '%s' "$OUT" | jq -e '[.agents[] | select((.repos | length) == 4)] | length == 1' >/dev/null \
  || fail "list --json must expose every repository, not just the first"
printf '%s' "$OUT" | jq -e '.summary.namedEnvironments == ["AgentScan E2E"]' >/dev/null \
  || fail "list --json must list the named environments present"
printf '%s' "$OUT" | jq -e '.summary.byEnvironment["AgentScan E2E"] == 1 and .summary.byEnvironment["(ad-hoc)"] == 2' >/dev/null \
  || fail "list --json must group agents by environment: $(printf '%s' "$OUT" | jq -c .summary.byEnvironment)"
printf '%s' "$OUT" | jq -e '[.agents[] | select(.envName == "AgentScan E2E")] | length == 1' >/dev/null \
  || fail "list --json must carry each agent's environment name"
pass "list --json emits fm-cursor-list.v1 with honest summary and per-agent provenance"

run_cursor show "$AGENT_SINGLE" --json
expect_code 0 "$RC" "show --json succeeds"
printf '%s' "$OUT" | jq -e '.schema == "fm-cursor-show.v1" and .latestRun.status == "FINISHED"' >/dev/null \
  || fail "show --json must carry its schema and the resolved latest run"

run_cursor show "$AGENT_SINGLE"
expect_code 0 "$RC" "show succeeds"
assert_contains "$OUT" "environment  prod (cloud)" "show names the environment and its type"
assert_contains "$OUT" "repositories 1 in this environment" "show frames repositories as belonging to the environment"
assert_contains "$OUT" "does not belong to any single repository" "show states the environment-is-the-unit rule"
pass "show leads with the environment rather than a repository"

run_cursor runs "$AGENT_SINGLE" --json
expect_code 0 "$RC" "runs --json succeeds"
printf '%s' "$OUT" | jq -e '.schema == "fm-cursor-runs.v1" and .count == 2' >/dev/null \
  || fail "runs --json must carry its schema and run count"
printf '%s' "$OUT" | jq -e '.runs[0].branches[0].prUrl == "https://github.com/snyk/minired/pull/94"' >/dev/null \
  || fail "runs --json must expose the PR URL"

run_cursor usage "$AGENT_SINGLE" --json
expect_code 0 "$RC" "usage --json succeeds"
printf '%s' "$OUT" | jq -e '.schema == "fm-cursor-usage.v1" and .costAvailable == false' >/dev/null \
  || fail "usage --json must carry its schema and declare cost unavailable"
printf '%s' "$OUT" | jq -e '.totalUsage.totalTokens == 46791544' >/dev/null \
  || fail "usage --json must pass through the token totals"
pass "show, runs, and usage each emit their documented schema"

run_cursor usage "$AGENT_SINGLE"
assert_contains "$OUT" "tokens only" "human usage states that no cost figure exists"
assert_contains "$OUT" "46791544" "human usage reports the token total"
pass "usage says plainly that Cursor reports tokens and no cost"

# --- (k) archived ------------------------------------------------------------

run_cursor list
assert_not_contains "$OUT" "Old archived thing" "archived agents are hidden by default"
assert_contains "$OUT" "pass --all" "the default view points at --all"
run_cursor list --all
assert_contains "$OUT" "Old archived thing" "--all includes archived agents"
assert_contains "$OUT" "archived" "--all shows the lifecycle column"
pass "archived agents are hidden by default and included with --all"

# --- (l) HTTP failures -------------------------------------------------------

fixture "/v1/agents/bc-9999zzzz" '{"code":"error","message":"Invalid User API Key"}'
fixture_code "/v1/agents/bc-9999zzzz" 401
run_cursor show bc-9999zzzz
expect_code 4 "$RC" "an API rejection exits 4"
assert_contains "$OUT" "rejected the key" "a 401 is explained as a key problem"
assert_contains "$OUT" "Invalid User API Key" "the API's own message is surfaced"
assert_not_contains "$OUT" "$KEY" "a failure message never contains the key"

fixture "/v1/agents/bc-8888yyyy" '{"code":"error","message":"Too Many Requests"}'
fixture_code "/v1/agents/bc-8888yyyy" 429
run_cursor show bc-8888yyyy
expect_code 4 "$RC" "a rate limit exits 4"
assert_contains "$OUT" "rate limited" "a 429 is explained as rate limiting"
pass "HTTP failures exit 4 with the API's message and never leak the key"

# --- (m) no temp credential file survives ------------------------------------

run_cursor list
while IFS= read -r cfg; do
  [ -n "$cfg" ] || continue
  assert_absent "$cfg" "the curl config holding the key must not survive the run"
done < "$CFGS"
[ -s "$CFGS" ] || fail "the fake curl should have recorded at least one config file"
pass "the temporary file holding the key is removed on exit"

# --- (n) default environment -------------------------------------------------

# Absent config: no default, no marker, and a bare --env has nothing to resolve.
assert_absent "$CONFIG_DIR/cursor-environment" "the fixture home starts with no default environment"
run_cursor list
expect_code 0 "$RC" "list works with no default environment configured"
assert_not_contains "$OUT" "default environment" "no default configured means no default footnote"
assert_not_contains "$OUT" "AgentScan E2E *" "no default configured means no marker"
run_cursor list --env
expect_code 2 "$RC" "a bare --env with no configured default exits 2"
assert_contains "$OUT" "cursor-environment" "the error names the config file to create"
pass "an absent config/cursor-environment means no default and a bare --env refuses"

# Present config, with a trailing newline and a comment line to prove the parse.
printf '# this home works on the shared stack\n\nAgentScan E2E\n' > "$CONFIG_DIR/cursor-environment"
run_cursor list
expect_code 0 "$RC" "list works with a default environment configured"
assert_contains "$OUT" "AgentScan E2E *" "the default environment is marked with *"
assert_contains "$OUT" "every environment is still listed" "the default must not silently filter"
# The whole point: a default must not hide the rest of the fleet.
printf '%s\n' "$OUT" | grep -q "(ad-hoc cloud)" \
  || fail "configuring a default must not hide agents outside it"
printf '%s\n' "$OUT" | grep -q "Single repo work" \
  || fail "configuring a default must not hide agents outside it"
pass "a configured default is marked but never filters list implicitly"

# A bare --env resolves to the configured default and narrows the view.
run_cursor list --env
expect_code 0 "$RC" "a bare --env succeeds once a default is configured"
assert_contains "$OUT" "AgentScan E2E" "the filtered view keeps the environment"
assert_not_contains "$OUT" "Single repo work" "--env excludes agents in other environments"
assert_contains "$OUT" "1 of 3 fetched" "the filtered footer reports matches against the fetch"
assert_contains "$OUT" "--limit bounds the fetch" "the filtered footer warns that --limit bounds the fetch"
# Filtering must precede run resolution, or a narrow filter costs a request per
# agent it is about to discard.
assert_no_grep "/v1/agents/bc-2222bbbb/runs/run-bbb1" "$CALLS" \
  "an agent filtered out by --env must not have its run resolved"
assert_grep "/v1/agents/bc-1111aaaa/runs/run-aaa1" "$CALLS" \
  "an agent kept by --env must still have its run resolved"
pass "a bare --env uses the configured default and filters before resolving runs"

# An explicit --env overrides the default, including to an environment with no
# agents, which must be an empty result rather than a silent fallback.
run_cursor list --env "Nonexistent Env"
expect_code 0 "$RC" "an --env with no matches still succeeds"
assert_contains "$OUT" "No Cursor Cloud agents found." "an unmatched --env reports an empty result"
assert_not_contains "$OUT" "AgentScan E2E *" "an unmatched --env must not fall back to the default"
# (o) An empty view under a filter must not read as "this home has no agents":
# the fetched count and the --limit caveat are exactly what turns "none" into
# "none on this page of the fetch".
assert_contains "$OUT" "0 of 3 fetched" "an unmatched --env still counts matches against the fetch"
assert_contains "$OUT" "--limit bounds the fetch" "an unmatched --env still carries the --limit caveat"
assert_contains "$OUT" "not an empty fleet" "an unmatched --env says agents were fetched"
run_cursor list --env ""
expect_code 2 "$RC" "an empty --env name exits 2 rather than selecting ad-hoc agents"
assert_contains "$OUT" "non-empty environment name" "an empty --env name is refused explicitly"

run_cursor list --env=AgentScan --json
expect_code 0 "$RC" "--env=<name> is accepted"
printf '%s' "$OUT" | jq -e '.environmentFilter == "AgentScan" and .count == 0' >/dev/null \
  || fail "--env=<name> must filter on the exact name, not a prefix"
pass "an explicit --env overrides the default and matches exactly"

run_cursor list --json
printf '%s' "$OUT" | jq -e '.defaultEnvironment == "AgentScan E2E" and .environmentFilter == null' >/dev/null \
  || fail "list --json must report the default without implying a filter"
printf '%s' "$OUT" | jq -e '.fetched == 3 and .count == 3' >/dev/null \
  || fail "an unfiltered list --json must report fetched == count"
pass "list --json reports the default environment separately from any filter"

# --- (p) one failed run resolution must not discard the listing --------------

run_cursor list --limit 5
expect_code 0 "$RC" "a failed per-agent run resolution must not abort the listing"
assert_contains "$OUT" "RUNNING" "the agent whose run resolves is still reported"
assert_contains "$OUT" "Stale run pointer" "the agent whose run failed is still listed"
assert_contains "$OUT" "2 agent(s) shown" "every fetched agent survives a failed resolution"
assert_contains "$OUT" "unknown" "an unresolvable latest run degrades to unknown"
assert_contains "$OUT" "could not be fetched" "the footer states how many runs went unresolved"
# A bare count cannot be acted on: the footer must name the reason too.
assert_contains "$OUT" "1 of them: not found (HTTP 404)" \
  "the footer names the reason a run went unresolved, grouped by reason"
assert_not_contains "$OUT" "$KEY" "no footer reason ever contains the key"
# The fast path failing must fall THROUGH to the runs-list fallback, not abort.
assert_grep "/v1/agents/$AGENT_STALERUN/runs/run-gone" "$CALLS" \
  "the stale latestRunId is still tried first"
assert_grep "/v1/agents/$AGENT_STALERUN/runs?limit=1" "$CALLS" \
  "a failed fast path must fall through to the runs-list fallback"
pass "a per-agent run request that fails costs one row, not the whole view"

# A 429 and a 401 must never read identically: the operator's next move differs.
run_cursor list --limit 6
expect_code 0 "$RC" "a rate-limited run resolution must not abort the listing"
assert_contains "$OUT" "rate limited by the Cursor API (HTTP 429)" \
  "a throttled resolution is reported as rate limiting, not as a missing run"
assert_contains "$OUT" "Too Many Requests" "the API's own message is carried into the reason"
assert_not_contains "$OUT" "not found" "a 429 must not be reported as a 404"
assert_not_contains "$OUT" "rejected the key" "a 429 must not be reported as a key problem"
run_cursor list --limit 6 --json
printf '%s' "$OUT" | jq -e '[.agents[] | select(.runStatusSource == "resolution-failed")
  | .runStatusReason] | length == 1 and (.[0] | test("429"))' >/dev/null \
  || fail "--json must carry the per-agent reason: $(printf '%s' "$OUT" | jq -c '[.agents[] | {runStatusSource, runStatusReason}]')"
printf '%s' "$OUT" | jq -e --arg k "$KEY" '[.agents[] | .runStatusReason // ""]
  | map(select(contains($k))) | length == 0' >/dev/null \
  || fail "a per-agent reason must never contain the key"
pass "a degraded row carries WHY, so rate limiting and a rejected key never look alike"

run_cursor list --limit 5 --json
expect_code 0 "$RC" "list --json succeeds with a failed resolution"
printf '%s' "$OUT" | jq -e '.count == 2' >/dev/null \
  || fail "a failed resolution must not drop the agent from --json"
printf '%s' "$OUT" | jq -e '[.agents[] | select(.runStatusSource == "resolution-failed")]
  | length == 1 and .[0].runStatus == "unknown"' >/dev/null \
  || fail "--json must distinguish a failed resolution: $(printf '%s' "$OUT" | jq -c '[.agents[] | {runStatus, runStatusSource}]')"
printf '%s' "$OUT" | jq -e '[.agents[] | select(.runStatusSource == "latestRunId")] | length == 1' >/dev/null \
  || fail "--json must still record the fast path for the agent that resolved"
printf '%s' "$OUT" | jq -e '[.agents[] | select(.runStatusSource == "latestRunId")
  | .runStatusReason] == [null]' >/dev/null \
  || fail "a resolved agent must carry no reason"
pass "runStatusSource tells a failed resolution apart from the fast path, fallback, and --no-runs"

# show degrades the same way list does. Dying with "not found (HTTP 404)" would
# read as "no such agent" for an agent GET /v1/agents/<id> just proved exists.
run_cursor show "$AGENT_STALERUN_SHOW"
expect_code 0 "$RC" "show renders the agent it fetched even when the latest run will not resolve"
assert_contains "$OUT" "latest run   unknown" "an unresolvable latest run shows as unknown"
assert_contains "$OUT" "not found (HTTP 404)" "show names why the run is unknown"
assert_contains "$OUT" "not because the agent is idle" "show says unknown is an absence of data"
assert_contains "$OUT" "Stale run pointer" "the agent's own detail is still rendered"
assert_not_contains "$OUT" "$KEY" "a degraded show never contains the key"
assert_grep "/v1/agents/$AGENT_STALERUN_SHOW/runs?limit=1" "$CALLS" \
  "show must try the runs-list fallback before giving up on the run"
run_cursor show "$AGENT_STALERUN_SHOW" --json
expect_code 0 "$RC" "show --json succeeds with an unresolvable latest run"
printf '%s' "$OUT" | jq -e '.latestRun.status == "unknown"
  and .latestRun.source == "resolution-failed"
  and (.latestRun.reason | test("404"))' >/dev/null \
  || fail "show --json must carry the unknown status with its reason: $(printf '%s' "$OUT" | jq -c .latestRun)"
printf '%s' "$OUT" | jq -e '.agent.id == "bc-6666ffff"' >/dev/null \
  || fail "show --json must still carry the agent that was fetched successfully"
pass "show reports an unresolvable run as unknown with the reason instead of dying"

# The TOP-LEVEL fetch of a subcommand is where a non-200 still means failure.
run_cursor show bc-9999zzzz
expect_code 4 "$RC" "a failed top-level agent fetch still exits 4"
run_cursor runs bc-9999zzzz
expect_code 4 "$RC" "a failed runs fetch still exits 4"
run_cursor usage bc-9999zzzz
expect_code 4 "$RC" "a failed usage fetch still exits 4"
pass "run resolution degrades while every top-level fetch still fails loudly"

# The ad-hoc environment label has two owners now - the shell env_label used by
# show and the inline jq used by list - so assert the show side too.
run_cursor show "$AGENT_ADHOC_SHOW"
expect_code 0 "$RC" "show succeeds for an agent with no named environment"
assert_contains "$OUT" "environment  (ad-hoc cloud) (cloud)" \
  "show renders an unnamed environment with the same ad-hoc label list uses"
assert_contains "$OUT" "created from a repository list" "show explains the ad-hoc case"
pass "list and show describe an unnamed environment identically"

# --- (q) FM_CURSOR_ENV_FILE --------------------------------------------------

ALT_ENV="$TMP_ROOT/alt.env"
printf 'CURSOR_API_KEY=%s\n' "$KEY" > "$ALT_ENV"
DECOY_HOME="$TMP_ROOT/decoyhome"
mkdir -p "$DECOY_HOME"
printf 'CURSOR_API_KEY=decoy_key_from_the_home_env\n' > "$DECOY_HOME/.env"
run_cursor_env FM_HOME="$DECOY_HOME" FM_CURSOR_ENV_FILE="$ALT_ENV" -- list --no-runs
expect_code 0 "$RC" "FM_CURSOR_ENV_FILE supplies the key"
# The fake curl asserts the config file carries the FIXTURE key, so a decoy key in
# $FM_HOME/.env winning would be recorded as a missing header rather than pass.
[ ! -s "$VIOLATIONS" ] || fail "FM_CURSOR_ENV_FILE must take precedence over \$FM_HOME/.env: $(cat "$VIOLATIONS")"
assert_not_contains "$OUT" "decoy_key_from_the_home_env" "no key is ever echoed back"

KEYLESS_ENV="$TMP_ROOT/keyless.env"
printf '# no key here\n' > "$KEYLESS_ENV"
run_cursor_env FM_CURSOR_ENV_FILE="$KEYLESS_ENV" -- list
expect_code 3 "$RC" "a keyless FM_CURSOR_ENV_FILE is not configured, even with a good \$FM_HOME/.env"
assert_contains "$OUT" "$KEYLESS_ENV" "the not-configured message names the overridden file"
[ ! -s "$CALLS" ] || fail "a keyless FM_CURSOR_ENV_FILE must be refused before any request"
pass "FM_CURSOR_ENV_FILE is the key's source when set, in both directions"

# --- (r) FM_CURSOR_TIMEOUT validation ----------------------------------------

# The timeout is interpolated into the same 0600 config file that carries the
# bearer header, and curl config syntax is one directive per line, so a value
# holding a newline would append directives of the attacker's choosing.
run_cursor_env FM_CURSOR_TIMEOUT="$(printf '30\nproxy = http://127.0.0.1:9')" -- list
expect_code 3 "$RC" "a timeout carrying a newline is refused"
assert_contains "$OUT" "FM_CURSOR_TIMEOUT" "the refusal names the variable"
[ ! -s "$CALLS" ] || fail "an injectable timeout must be refused before any request"
run_cursor_env FM_CURSOR_TIMEOUT=abc -- list
expect_code 3 "$RC" "a non-numeric timeout is refused instead of degrading to a reach error"
run_cursor_env FM_CURSOR_TIMEOUT=0 -- list
expect_code 3 "$RC" "a zero timeout is refused"
run_cursor_env FM_CURSOR_TIMEOUT=99999 -- list
expect_code 3 "$RC" "an out-of-range timeout is refused"
run_cursor_env FM_CURSOR_TIMEOUT=5 -- list --no-runs
expect_code 0 "$RC" "a plain numeric timeout is accepted"
pass "FM_CURSOR_TIMEOUT is validated before it can inject into the key's config file"

# --- (s) mutating verbs ------------------------------------------------------
#
# These act on a live fleet, so the refusals matter more than the happy paths.

BODIES="$TMP_ROOT/bodies"
export FM_CURSOR_TEST_BODIES="$BODIES"

AGENT_IDLE=bc-aaaa1111
AGENT_BUSY=bc-bbbb2222
AGENT_NORUNS=bc-cccc3333

fixture "/v1/agents/$AGENT_IDLE/runs?limit=1" \
  '{"items":[{"id":"run-idle9","status":"FINISHED","createdAt":"2026-07-30T10:00:00.000Z","durationMs":1000,"git":{"branches":[]}}]}'
fixture "/v1/agents/$AGENT_BUSY/runs?limit=1" \
  '{"items":[{"id":"run-busy9","status":"RUNNING","createdAt":"2026-07-31T10:00:00.000Z","durationMs":null,"git":{"branches":[]}}]}'
fixture "/v1/agents/$AGENT_NORUNS/runs?limit=1" '{"items":[]}'

# --- refusal: never steer or archive an agent whose run is still going.
run_cursor send "$AGENT_BUSY" please also update the tests
expect_code 5 "$RC" "send refuses a busy agent"
assert_contains "$OUT" "busy" "the refusal says the agent is busy"
assert_contains "$OUT" "run-busy9" "the refusal names the run that is active"
assert_no_grep "POST" "$CALLS" "a refused send must issue no POST at all"

run_cursor archive "$AGENT_BUSY"
expect_code 5 "$RC" "archive refuses a busy agent"
assert_no_grep "POST" "$CALLS" "a refused archive must issue no POST"
pass "send and archive refuse a busy agent before issuing any request"

# --- refusal when the state cannot be determined: never act blind.
fixture "/v1/agents/bc-dddd4444/runs?limit=1" '{"message":"Too Many Requests"}'
fixture_code "/v1/agents/bc-dddd4444/runs?limit=1" 429
run_cursor send bc-dddd4444 "do something"
expect_code 5 "$RC" "send refuses when the run state is unknown"
assert_contains "$OUT" "cannot tell" "the refusal says the state could not be determined"
assert_no_grep "POST" "$CALLS" "an unknown-state send must issue no POST"
pass "an indeterminate run state is a refusal, not an optimistic send"

# --- happy path: the follow-up body carries the prompt and NEVER mcpServers.
: > "$BODIES"
fixture_post "/v1/agents/$AGENT_IDLE/runs" \
  '{"id":"run-new1","status":"CREATING","agentId":"bc-aaaa1111"}'
run_cursor send "$AGENT_IDLE" refactor the auth module
expect_code 0 "$RC" "send succeeds on an idle agent"
assert_grep "POST https://api.cursor.com/v1/agents/$AGENT_IDLE/runs" "$CALLS" \
  "send posts to the agent's runs endpoint"
assert_contains "$OUT" "run-new1" "send reports the new run id"
jq -e '.prompt.text == "refactor the auth module"' "$BODIES" >/dev/null \
  || fail "the follow-up body must carry the prompt text verbatim: $(cat "$BODIES")"
jq -e 'has("mcpServers") | not' "$BODIES" >/dev/null \
  || fail "a follow-up must NEVER send mcpServers - the API replaces the agent's set and strips its tools"
pass "send posts the prompt and never sends mcpServers"

# --- a 409 losing the race is a clean refusal, not a crash.
fixture_post "/v1/agents/$AGENT_IDLE/runs" '{"message":"agent_busy"}'
fixture_post_code "/v1/agents/$AGENT_IDLE/runs" 409
run_cursor send "$AGENT_IDLE" another prompt
expect_code 5 "$RC" "a 409 race exits 5 as a refusal"
assert_contains "$OUT" "became busy" "the 409 refusal explains the race"
assert_contains "$OUT" "Nothing was sent" "the 409 refusal says nothing was sent"
pass "a 409 from a race is a clean refusal rather than a stack trace"

# --- cancel targets the active run, and refuses when there is nothing to cancel.
fixture_post "/v1/agents/$AGENT_BUSY/runs/run-busy9/cancel" '{"ok":true}'
run_cursor cancel "$AGENT_BUSY"
expect_code 0 "$RC" "cancel succeeds on a running agent"
assert_grep "POST https://api.cursor.com/v1/agents/$AGENT_BUSY/runs/run-busy9/cancel" "$CALLS" \
  "cancel posts to the ACTIVE run's cancel endpoint"
run_cursor cancel "$AGENT_IDLE"
expect_code 5 "$RC" "cancel refuses when the latest run is already terminal"
assert_contains "$OUT" "nothing to cancel" "the refusal says there is nothing to cancel"
run_cursor cancel "$AGENT_NORUNS"
expect_code 5 "$RC" "cancel refuses an agent with no runs"
pass "cancel acts only on a genuinely active run"

# --- archive/unarchive are the reversible pair, and DELETE is not wired at all.
fixture_post "/v1/agents/$AGENT_IDLE/archive" '{"ok":true}'
fixture_post "/v1/agents/$AGENT_IDLE/unarchive" '{"ok":true}'
run_cursor archive "$AGENT_IDLE"
expect_code 0 "$RC" "archive succeeds on an idle agent"
assert_grep "POST https://api.cursor.com/v1/agents/$AGENT_IDLE/archive" "$CALLS" "archive posts to /archive"
assert_contains "$OUT" "reversible" "archive says it is reversible"
run_cursor unarchive "$AGENT_IDLE"
expect_code 0 "$RC" "unarchive succeeds"
assert_grep "POST https://api.cursor.com/v1/agents/$AGENT_IDLE/unarchive" "$CALLS" "unarchive posts to /unarchive"
run_cursor delete "$AGENT_IDLE"
expect_code 2 "$RC" "there is deliberately no delete subcommand"
assert_contains "$OUT" "unknown subcommand" "delete is not a recognised verb"
pass "archive and unarchive are wired, delete deliberately is not"

# --- every mutating verb demands an explicit id: no default, no wildcard.
for verb in send cancel archive unarchive; do
  run_cursor "$verb"
  expect_code 2 "$RC" "$verb without an agent id exits 2"
  run_cursor "$verb" '*'
  expect_code 2 "$RC" "$verb refuses a wildcard agent id"
done
pass "no mutating verb accepts a missing or wildcard agent id"

# --- (x) create names the environment and never enumerates repos -------------

printf 'AgentScan E2E\n' > "$CONFIG_DIR/cursor-environment"
fixture "/v1/models" '{"models":[{"id":"composer-2.5"},{"id":"claude-opus-5"}]}'
fixture_post "/v1/agents" \
  '{"agent":{"id":"bc-new55555","status":"ACTIVE","url":"https://cursor.com/agents/bc-new55555","env":{"type":"cloud","name":"AgentScan E2E"}},"run":{"id":"run-new55","status":"CREATING"}}'

: > "$BODIES"
run_cursor create --prompt "add a smoke test"
expect_code 0 "$RC" "create succeeds using the configured default environment"
assert_grep "POST https://api.cursor.com/v1/agents" "$CALLS" "create posts to /v1/agents"
jq -e '.env.name == "AgentScan E2E" and .env.type == "cloud"' "$BODIES" >/dev/null \
  || fail "create must NAME the environment: $(cat "$BODIES")"
jq -e 'has("repos") | not' "$BODIES" >/dev/null \
  || fail "create must NEVER enumerate repos - repos and a named env are mutually exclusive and the env carries the secrets"
jq -e '.prompt.text == "add a smoke test"' "$BODIES" >/dev/null || fail "create must carry the prompt"
assert_contains "$OUT" "https://cursor.com/agents/bc-new55555" "create prints the agent url"
assert_contains "$OUT" "AgentScan E2E" "create names the environment it used"
pass "create names the default environment, never enumerates repos, and prints the url"

: > "$BODIES"
run_cursor create --env "Other Env" --prompt hi --model composer-2.5
expect_code 0 "$RC" "an explicit --env and a catalog model are accepted"
jq -e '.env.name == "Other Env" and .model.id == "composer-2.5"' "$BODIES" >/dev/null \
  || fail "create must honour an explicit --env and --model: $(cat "$BODIES")"

run_cursor create --prompt hi --model not-a-real-model
expect_code 2 "$RC" "a model outside the account catalog exits 2"
assert_contains "$OUT" "not in this account's catalog" "the model error names the problem"
assert_contains "$OUT" "composer-2.5" "the model error lists what is available"
assert_no_grep "POST" "$CALLS" "an invalid model must be rejected before any create POST"

run_cursor create --env "Other Env"
expect_code 2 "$RC" "create without a prompt exits 2"
rm -f "$CONFIG_DIR/cursor-environment"
run_cursor create --prompt hi
expect_code 2 "$RC" "create with no --env and no configured default exits 2"
assert_contains "$OUT" "cursor-environment" "the error points at the config file"
printf 'AgentScan E2E\n' > "$CONFIG_DIR/cursor-environment"
pass "create validates the model against the live catalog and demands an environment"

# --- (aa) the --no-runs footer must never imply anything about activity ------

run_cursor list --no-runs
expect_code 0 "$RC" "list --no-runs succeeds"
assert_not_contains "$OUT" "with a run in flight" \
  "--no-runs must not assert an in-flight count after resolving nothing"
assert_contains "$OUT" "none of whose runs were resolved" "--no-runs says nothing was resolved"
pass "--no-runs never lets an unresolved row read as idle"

# --- (bb) an API-supplied name cannot break the table -----------------------
#
# The row record is separator-delimited, so a name carrying that separator, a
# newline or a tab would split or truncate its row if it were not sanitised.
SEP=$(printf '\037')
TAB=$(printf '\t')
fixture "/v1/agents?limit=20&includeArchived=false" "$(jq -nc \
  --arg hostile "Break${SEP}the${TAB}row" \
  '{items:[{id:"bc-9999hostile",name:$hostile,status:"ACTIVE",latestRunId:"run-h1",
            createdAt:"2026-07-30T10:00:00.000Z",updatedAt:"2026-07-30T10:00:00.000Z",
            url:"https://cursor.com/agents/bc-9999hostile",env:{type:"cloud"},
            repos:[{url:"https://github.com/snyk/minired"}]}]}')"
fixture "/v1/agents/bc-9999hostile/runs/run-h1" \
  '{"id":"run-h1","status":"FINISHED","durationMs":1000,"git":{"branches":[]}}'
run_cursor list
expect_code 0 "$RC" "list survives an agent name containing the record separator"
assert_contains "$OUT" "1 agent(s) shown" "the hostile name must not split the row into extra rows"
assert_contains "$OUT" "FINISHED" "the hostile row still renders its run status"
assert_contains "$OUT" "Break the row" "the separator and tab are collapsed to spaces"
pass "an API-supplied name cannot split or truncate a table row"

# --- (cc) runs --json hydrates the result the LIST endpoint omits -------------
#
# The list endpoint returns no `result` field even for a FINISHED run, while the
# individual run returns it populated. bin/fm-bare-metal.sh writes its return
# handoff from that field, so a consumer trusting the list item silently loses the
# cloud agent's entire reasoning.

AGENT_RESULT=bc-1010resu
fixture "/v1/agents/$AGENT_RESULT/runs?limit=3" '{"items":[
  {"id":"run-fin1","status":"FINISHED","createdAt":"2026-08-01T09:00:00.000Z",
   "updatedAt":"2026-08-01T09:10:00.000Z","durationMs":600000,
   "git":{"branches":[{"repoUrl":"github.com/snyk/minired","branch":"cursor/x"}]}},
  {"id":"run-live1","status":"RUNNING","createdAt":"2026-08-01T09:20:00.000Z",
   "updatedAt":"2026-08-01T09:21:00.000Z","durationMs":null,"git":{"branches":[]}},
  {"id":"run-fin2","status":"FINISHED","createdAt":"2026-08-01T08:00:00.000Z",
   "updatedAt":"2026-08-01T08:05:00.000Z","durationMs":300000,"git":{"branches":[]}}
]}'
fixture "/v1/agents/$AGENT_RESULT/runs/run-fin1" \
  '{"id":"run-fin1","status":"FINISHED","durationMs":600000,"result":"THE FINAL TEXT the list endpoint omits","git":{"branches":[]}}'
fixture "/v1/agents/$AGENT_RESULT/runs/run-fin2" \
  '{"id":"run-fin2","status":"FINISHED","durationMs":300000,"git":{"branches":[]}}'

run_cursor runs "$AGENT_RESULT" --limit 3 --json
expect_code 0 "$RC" "runs --json succeeds while hydrating results"
printf '%s' "$OUT" | jq -e '.runs[0].result == "THE FINAL TEXT the list endpoint omits"' >/dev/null \
  || fail "a terminal run's result must be hydrated from the individual run: $OUT"
printf '%s' "$OUT" | jq -e '.runs[0].resultSource == "run-detail"' >/dev/null \
  || fail "the hydrated result must record where it came from: $OUT"
printf '%s' "$OUT" | jq -e '.runs[1].resultSource == "pending" and .runs[1].result == null' >/dev/null \
  || fail "a RUNNING run has no result yet and must not be hydrated: $OUT"
printf '%s' "$OUT" | jq -e '.runs[2].resultSource == "absent"' >/dev/null \
  || fail "a terminal run whose detail carries no result must read as absent, not as unavailable: $OUT"
assert_no_grep "GET https://api.cursor.com/v1/agents/$AGENT_RESULT/runs/run-live1" "$CALLS" \
  "hydration must cost no request for a run that cannot have a result yet"
assert_grep "GET https://api.cursor.com/v1/agents/$AGENT_RESULT/runs/run-fin1" "$CALLS" \
  "a terminal run with no result in the list item is fetched individually"
pass "runs --json hydrates the result the list endpoint omits, and only where it can exist"

run_cursor runs "$AGENT_RESULT" --limit 3 --json --no-result
expect_code 0 "$RC" "runs --json --no-result succeeds"
printf '%s' "$OUT" | jq -e '[.runs[].resultSource] | all(. == "skipped")' >/dev/null \
  || fail "--no-result must skip hydration and say so: $OUT"
assert_no_grep "/runs/run-fin1" "$CALLS" "--no-result must issue no per-run request"
pass "--no-result skips hydration entirely"

fixture_code "/v1/agents/$AGENT_RESULT/runs/run-fin1" 429
fixture "/v1/agents/$AGENT_RESULT/runs/run-fin1" '{"message":"slow down"}'
run_cursor runs "$AGENT_RESULT" --limit 3 --json
expect_code 0 "$RC" "a failed hydration must not fail the whole history"
printf '%s' "$OUT" | jq -e '.runs[0].resultSource == "unavailable"' >/dev/null \
  || fail "a failed hydration must degrade to unavailable: $OUT"
printf '%s' "$OUT" | jq -e '.runs[0].resultReason | test("429")' >/dev/null \
  || fail "the degraded run must carry the reason, so a rate limit never reads as an empty result: $OUT"
printf '%s' "$OUT" | jq -e '.count == 3' >/dev/null || fail "the rest of the history must survive: $OUT"
printf '%s' "$OUT" | jq -e '[.runs[].resultSource] | index("needs-hydration") == null' >/dev/null \
  || fail "the internal hydration marker must never reach a consumer: $OUT"
rm -f "$FIXTURES/$(printf '%s' "api.cursor.com/v1/agents/$AGENT_RESULT/runs/run-fin1" | sed 's/[^A-Za-z0-9]/_/g').code"
pass "a failed hydration degrades one run with its reason and keeps the rest"

# --- watch fixtures ----------------------------------------------------------

fixture_sse() {  # <url-path> <sse-text>
  local slug
  slug=$(printf '%s' "api.cursor.com$1" | sed 's/[^A-Za-z0-9]/_/g')
  printf '%s' "$2" > "$FIXTURES/$slug.sse"
}

fixture_sse_resume() {  # <url-path> <sse-text>
  local slug
  slug=$(printf '%s' "api.cursor.com$1" | sed 's/[^A-Za-z0-9]/_/g')
  printf '%s' "$2" > "$FIXTURES/$slug.resume.sse"
}

fixture_stream_code() {  # <url-path> <http-code>
  local slug
  slug=$(printf '%s' "api.cursor.com$1" | sed 's/[^A-Za-z0-9]/_/g')
  printf '%s' "$2" > "$FIXTURES/$slug.stream-code"
}

fixture_retention() {  # <url-path> <seconds>
  local slug
  slug=$(printf '%s' "api.cursor.com$1" | sed 's/[^A-Za-z0-9]/_/g')
  printf '%s' "$2" > "$FIXTURES/$slug.retention"
}

AGENT_WATCH=bc-2020watc
WATCH_STREAM="/v1/agents/$AGENT_WATCH/runs/run-w1/stream"
# The agent's latest run is RUNNING, so watch attaches instead of refusing...
fixture "/v1/agents/$AGENT_WATCH/runs?limit=1" \
  '{"items":[{"id":"run-w1","status":"RUNNING","createdAt":"2026-08-01T09:00:00.000Z","updatedAt":"2026-08-01T09:01:00.000Z","durationMs":null,"git":{"branches":[]}}]}'
# ...and the run RECORD is what the outcome is confirmed against afterwards.
fixture "/v1/agents/$AGENT_WATCH/runs/run-w1" \
  '{"id":"run-w1","status":"FINISHED","durationMs":60000,"result":"the run record final text","git":{"branches":[]}}'
fixture_retention "$WATCH_STREAM" 86400

# --- (dd) a live run renders as readable prose, heartbeats excluded ----------

fixture_sse "$WATCH_STREAM" 'id: ev-1
event: status
data: {"runId":"run-w1","status":"RUNNING"}

id: ev-2
event: thinking
data: {"text":"weighing the options"}

id: ev-3
event: heartbeat
data: {"beat":"NEVER_PRINT_THIS_HEARTBEAT"}

id: ev-4
event: interaction_update
data: {"type":"text-delta","text":"NEVER_PRINT_THIS_DUPLICATE","tokens":7}

id: ev-5
event: assistant
data: {"text":"the answer is 42"}

id: ev-6
event: tool_call
data: {"callId":"c1","name":"read_file","status":"running"}

id: ev-7
event: tool_call
data: {"callId":"c1","name":"read_file","status":"completed"}

id: ev-8
event: result
data: {"runId":"run-w1","status":"FINISHED","text":"the stream final text"}

id: ev-9
event: done
data: {}

'

run_cursor watch "$AGENT_WATCH"
expect_code 0 "$RC" "watching a live run exits 0"
assert_contains "$OUT" "[assistant] the answer is 42" "assistant text renders as prose"
assert_contains "$OUT" "[thinking] weighing the options" "thinking renders as prose"
assert_contains "$OUT" "[tool] read_file running" "a tool call renders its name and state"
assert_contains "$OUT" "[tool] read_file completed" "a tool call's completion renders too"
assert_contains "$OUT" "[result] FINISHED" "the result event renders"
assert_contains "$OUT" "the stream final text" "the result text renders"
assert_contains "$OUT" "[done]" "the done event ends the watch"
assert_not_contains "$OUT" "NEVER_PRINT_THIS_HEARTBEAT" \
  "a heartbeat must never be rendered as content"
assert_not_contains "$OUT" "NEVER_PRINT_THIS_DUPLICATE" \
  "interaction_update duplicates assistant/thinking and must not be printed twice"
assert_contains "$OUT" "1 heartbeat(s)" "the heartbeat is still counted for liveness"
assert_contains "$OUT" "7 token(s) reported" "token accounting comes from interaction_update"
assert_contains "$OUT" "86400s" "the retention window the server reported is stated"
assert_contains "$OUT" "is FINISHED, from the run record rather than from the stream" \
  "the outcome is confirmed against the run record, not taken from the stream"
assert_grep "GET https://api.cursor.com/v1/agents/$AGENT_WATCH/runs/run-w1" "$CALLS" \
  "the run record is read to confirm the outcome"
pass "watch renders a live run as readable prose and confirms the outcome against the poll's own source"

# A paragraph break arrives as its own text delta carrying nothing but newlines.
# Dropping it - which a command substitution does silently - runs the agent's
# paragraphs together, so the rendered text has to preserve it.
fixture_sse "$WATCH_STREAM" 'id: ev-1
event: assistant
data: {"text":"FIRST PARAGRAPH"}

id: ev-2
event: assistant
data: {"text":"\n\n"}

id: ev-3
event: assistant
data: {"text":"SECOND PARAGRAPH"}

id: ev-4
event: done
data: {}

'
run_cursor watch "$AGENT_WATCH"
expect_code 0 "$RC" "a stream whose deltas include a blank-line delta exits 0"
assert_contains "$OUT" "FIRST PARAGRAPH" "the first paragraph renders"
assert_contains "$OUT" "SECOND PARAGRAPH" "the second paragraph renders"
assert_not_contains "$OUT" "FIRST PARAGRAPHSECOND PARAGRAPH" \
  "a newline-only text delta must not be dropped, which would run paragraphs together"
pass "a text delta that is only newlines is preserved rather than swallowed"

# --- (ee) a mid-stream disconnect resumes from the last event seen -----------

fixture_sse "$WATCH_STREAM" 'id: ev-1
event: assistant
data: {"text":"FIRST HALF ONLY"}

id: ev-2
event: thinking
data: {"text":"still going"}

'
fixture_sse_resume "$WATCH_STREAM" 'id: ev-3
event: assistant
data: {"text":"SECOND HALF AFTER RESUME"}

id: ev-4
event: done
data: {}

'
# A generous timeout so a heavily loaded machine cannot turn "the stream dropped
# and was resumed" into "the watch timed out" and make this case flaky.
run_cursor watch "$AGENT_WATCH" --attempts 2 --timeout 21600
expect_code 0 "$RC" "a dropped stream that resumes still exits 0"
assert_grep "RESUME ev-2" "$RESUMES" \
  "the reconnection must carry Last-Event-ID with the last event actually seen"
assert_contains "$OUT" "SECOND HALF AFTER RESUME" "the resumed stream's events are rendered"
assert_contains "$OUT" "reconnecting (1 of 2)" "the reconnection is reported, not hidden"
assert_contains "$OUT" "[done]" "the resumed stream reaches the end"
[ "$(grep -c 'FIRST HALF ONLY' <<<"$OUT")" = 1 ] \
  || fail "a resume must continue rather than replay from the start: $OUT"
[ "$(grep -c 'GET .*/stream' "$RESUMES")" = 2 ] \
  || fail "expected exactly two stream connections: $(cat "$RESUMES")"
pass "a mid-stream disconnect resumes from the last event rather than restarting"

run_cursor watch "$AGENT_WATCH" --attempts 0
expect_code 0 "$RC" "--attempts 0 still exits 0 after the stream drops"
assert_contains "$OUT" "reconnection attempt(s) allowed were used" \
  "exhausting the attempt budget is reported as the reason"
assert_contains "$OUT" "is FINISHED, from the run record" \
  "an incomplete stream still reports the authoritative run state"
assert_contains "$OUT" "the watcher poll still reports its outcome" \
  "a degraded live view says plainly that the poll is unaffected"
[ "$(grep -c 'GET .*/stream' "$RESUMES")" = 1 ] \
  || fail "--attempts 0 must not reconnect: $(cat "$RESUMES")"
pass "the reconnection budget is bounded and its exhaustion is reported, not hidden"

# --- (ff) an expired stream falls back to the run record ---------------------

fixture_stream_code "$WATCH_STREAM" 410
fixture_sse "$WATCH_STREAM" '{"error":"stream_expired","message":"RAW_BODY_MUST_NOT_LEAK"}'
run_cursor watch "$AGENT_WATCH"
expect_code 0 "$RC" "an expired stream must not fail the command"
assert_contains "$OUT" "expired" "the expiry is named as what happened"
assert_contains "$OUT" "is FINISHED, from the run record rather than from the stream" \
  "a 410 falls back to the run endpoint for terminal state"
assert_not_contains "$OUT" "RAW_BODY_MUST_NOT_LEAK" \
  "a non-SSE error body must never be rendered as stream content"
[ "$(grep -c 'GET .*/stream' "$RESUMES")" = 1 ] \
  || fail "an expired stream must not be retried: $(cat "$RESUMES")"
pass "410 stream_expired falls back to the run record and says that is what happened"

fixture_stream_code "$WATCH_STREAM" 429
run_cursor watch "$AGENT_WATCH"
expect_code 0 "$RC" "a rate-limited stream must not fail the command"
assert_contains "$OUT" "rate limited" "the rate limit is named"
assert_contains "$OUT" "is FINISHED, from the run record" "the run state is still reported"
[ "$(grep -c 'GET .*/stream' "$RESUMES")" = 1 ] \
  || fail "a rate-limited stream must back off rather than reconnect: $(cat "$RESUMES")"
fixture_stream_code "$WATCH_STREAM" 200
pass "a rate-limited stream backs off instead of reconnecting, and still reports the run"

# --- (gg) --json emits one object per event, then one summary ----------------

fixture_sse "$WATCH_STREAM" 'id: ev-1
event: heartbeat
data: {"beat":1}

id: ev-2
event: assistant
data: {"text":"quoted \" and \\ and a tab\tinside"}

id: ev-3
event: done
data: {}

'
run_cursor watch "$AGENT_WATCH" --json
expect_code 0 "$RC" "watch --json exits 0"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf '%s' "$line" | jq -e . >/dev/null 2>&1 \
    || fail "every --json line must be one parseable JSON object; this one is not: $line"
done <<< "$OUT"
[ "$(printf '%s\n' "$OUT" | jq -r 'select(.schema == "fm-cursor-watch-event.v1") | .event' | tr '\n' ' ')" \
  = "heartbeat assistant done " ] \
  || fail "--json must carry every event including heartbeats, in order: $OUT"
printf '%s\n' "$OUT" | tail -1 | jq -e '.schema == "fm-cursor-watch.v1"
    and .streamReachedEnd == true and .heartbeats == 1 and .retentionSeconds == 86400
    and .runStatus == "FINISHED" and .runStatusSource == "run-detail"' >/dev/null \
  || fail "the last --json line must be the summary, with the poll-confirmed run state: $OUT"
pass "watch --json emits one parseable object per event and a final summary"

# --- (hh) a run that has already ended is not streamed unless asked ---------

AGENT_DONE=bc-3030done
fixture "/v1/agents/$AGENT_DONE/runs?limit=1" \
  '{"items":[{"id":"run-d1","status":"FINISHED","createdAt":"2026-08-01T09:00:00.000Z","updatedAt":"2026-08-01T09:05:00.000Z","durationMs":300000,"git":{"branches":[]}}]}'
fixture "/v1/agents/$AGENT_DONE/runs/run-d1" \
  '{"id":"run-d1","status":"FINISHED","durationMs":300000,"result":"THE FINISHED RUN FINAL TEXT","git":{"branches":[]}}'
fixture_sse "/v1/agents/$AGENT_DONE/runs/run-d1/stream" 'id: ev-1
event: assistant
data: {"text":"REPLAYED HISTORY"}

id: ev-2
event: done
data: {}

'
run_cursor watch "$AGENT_DONE"
expect_code 0 "$RC" "watching a finished run exits 0"
assert_contains "$OUT" "has already ended: FINISHED" "a finished run is reported, not streamed"
assert_contains "$OUT" "THE FINISHED RUN FINAL TEXT" "the agent's final text is what an operator wanted"
assert_contains "$OUT" "--replay" "the replay option is offered rather than assumed"
[ ! -s "$RESUMES" ] || fail "a finished run must not be streamed without --replay: $(cat "$RESUMES")"
pass "a finished run answers with its final text instead of replaying thousands of events"

run_cursor watch "$AGENT_DONE" --replay
expect_code 0 "$RC" "--replay on a finished run exits 0"
assert_contains "$OUT" "REPLAYED HISTORY" "--replay streams the run's history"
assert_grep "/runs/run-d1/stream" "$RESUMES" "--replay does connect to the stream"
pass "--replay streams a finished run's history on request"

# --- (ii) watch usage errors and refusals -----------------------------------

run_cursor watch
expect_code 2 "$RC" "watch without an agent id exits 2"
run_cursor watch "$AGENT_WATCH" --timeout 2
expect_code 2 "$RC" "a --timeout below the allowed range exits 2"
run_cursor watch "$AGENT_WATCH" --timeout 999999
expect_code 2 "$RC" "a --timeout above the allowed range exits 2"
run_cursor watch "$AGENT_WATCH" --timeout abc
expect_code 2 "$RC" "a non-numeric --timeout exits 2"
run_cursor watch "$AGENT_WATCH" --attempts 99
expect_code 2 "$RC" "an out-of-range --attempts exits 2"
run_cursor watch "$AGENT_WATCH" --run 'bad id'
expect_code 2 "$RC" "an invalid run id exits 2"
run_cursor watch "$AGENT_WATCH" --nonsense
expect_code 2 "$RC" "an unknown watch option exits 2"
assert_no_grep "stream" "$RESUMES" "no usage error may open a stream"

AGENT_NORUNS=bc-4040none
fixture "/v1/agents/$AGENT_NORUNS/runs?limit=1" '{"items":[]}'
run_cursor watch "$AGENT_NORUNS"
expect_code 5 "$RC" "an agent with no runs is a refusal, not a hang"
assert_contains "$OUT" "no runs to watch" "the refusal names the situation"

AGENT_BLIND=bc-5050blin
fixture "/v1/agents/$AGENT_BLIND/runs?limit=1" '{"message":"slow down"}'
fixture_code "/v1/agents/$AGENT_BLIND/runs?limit=1" 429
run_cursor watch "$AGENT_BLIND"
expect_code 5 "$RC" "an indeterminate run state refuses rather than attaching blind"
assert_contains "$OUT" "Refusing to attach blind" "the refusal explains why"
assert_contains "$OUT" "429" "the refusal carries the reason the state is unknown"
pass "watch validates its options and refuses rather than attaching to nothing"

printf '\nall fm-cursor tests passed\n'
