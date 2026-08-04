#!/usr/bin/env bash
# Behavior tests for the local-only firstmate dashboard.
# Covers rendering from the bearings snapshot contract, the public loopback bind
# promise, and loud refusal when the requested port is already taken.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dashboard)

free_port() {
  python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

make_dashboard_fixture() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-dashboard.sh" "$dir/bin/fm-dashboard.sh"
  cat > "$dir/bin/fm-bearings-snapshot.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --json)
    : "${SNAPSHOT_COUNT:?SNAPSHOT_COUNT is required}"
    count=0
    [ ! -f "$SNAPSHOT_COUNT" ] || count=$(cat "$SNAPSHOT_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$SNAPSHOT_COUNT"
    cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "generated": "2026-08-04T10:30:00+02:00",
  "in_flight": [{"id":"fmdash","kind":"ship","state":"working","doing":"building the dashboard"}],
  "decisions_open": [{"id":"review-ui","key":"ui-choice","verb":"choose","summary":"Pick the dashboard wording","owner":"captain"}],
  "gates": [{"id":"later","title":"Follow-up work","blocked_by":"review-ui","reason":"waiting for the decision","owner":"captain"}],
  "landed": [{"id":"done-a","what":"Dashboard groundwork landed","artifact":"https://github.com/kunchenguid/firstmate/pull/7","owner":"firstmate"}],
  "recorded_prs": [{"id":"fmdash","url":"https://github.com/kunchenguid/firstmate/pull/99"}],
  "unhealthy_endpoints": [{"id":"worker-a","reason":"stopped responding"}],
  "omitted": [{"surface":"reports","reveal":"--all-reports"}]
}
JSON
    ;;
  *)
    echo "unexpected snapshot call: $*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$dir/bin/fm-dashboard.sh" "$dir/bin/fm-bearings-snapshot.sh"
}

fetch_url() {  # <url>
  python3 - "$1" <<'PY'
import sys
import urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=5) as response:
    sys.stdout.write(response.read().decode("utf-8"))
PY
}

wait_for_log() {  # <file> <needle>
  local file=$1 needle=$2 attempts=0
  while [ "$attempts" -lt 50 ]; do
    [ -f "$file" ] && grep -Fq "$needle" "$file" && return 0
    attempts=$((attempts + 1))
    sleep 0.1
  done
  return 1
}

stop_pid() {  # <pid>
  local pid=$1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_renders_fixture_snapshot() {
  local fixture port log html count_file pid
  fixture="$TMP_ROOT/render"
  make_dashboard_fixture "$fixture"
  port=$(free_port)
  log="$fixture/dashboard.log"
  count_file="$fixture/snapshot-count"
  SNAPSHOT_COUNT="$count_file" "$fixture/bin/fm-dashboard.sh" --port "$port" --refresh 5 >"$log" 2>&1 &
  pid=$!
  wait_for_log "$log" "http://127.0.0.1:$port/" || { stop_pid "$pid"; fail "dashboard did not start"; }
  html=$(fetch_url "http://127.0.0.1:$port/") || { stop_pid "$pid"; fail "dashboard did not return HTML"; }
  stop_pid "$pid"

  assert_contains "$html" "What needs me" "dashboard did not put captain decisions first"
  assert_contains "$html" "Pick the dashboard wording" "dashboard did not render open decisions"
  assert_contains "$html" "building the dashboard" "dashboard did not render open workers"
  assert_contains "$html" "https://github.com/kunchenguid/firstmate/pull/99" "dashboard did not render full PR URL"
  assert_contains "$html" "<th>#</th>" "dashboard tables did not include a numbered column"
  [ "$(cat "$count_file")" -eq 1 ] || fail "dashboard did not call the snapshot once for one request"
  pass "dashboard renders HTML from a bearings snapshot fixture"
}

test_binds_loopback() {
  local fixture port log pid
  fixture="$TMP_ROOT/loopback"
  make_dashboard_fixture "$fixture"
  port=$(free_port)
  log="$fixture/dashboard.log"
  SNAPSHOT_COUNT="$fixture/snapshot-count" "$fixture/bin/fm-dashboard.sh" --port "$port" --refresh 5 >"$log" 2>&1 &
  pid=$!
  wait_for_log "$log" "fm-dashboard: serving http://127.0.0.1:$port/" || { stop_pid "$pid"; fail "dashboard did not announce a loopback bind"; }
  stop_pid "$pid"
  pass "dashboard binds and announces 127.0.0.1"
}

test_taken_port_fails_loudly() {
  local fixture port blocker_pid out rc
  fixture="$TMP_ROOT/taken"
  make_dashboard_fixture "$fixture"
  port=$(free_port)
  python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
  blocker_pid=$!
  sleep 0.3
  rc=0
  out=$(SNAPSHOT_COUNT="$fixture/snapshot-count" "$fixture/bin/fm-dashboard.sh" --port "$port" --refresh 5 2>&1) || rc=$?
  stop_pid "$blocker_pid"
  [ "$rc" -ne 0 ] || fail "dashboard succeeded on a taken port"
  assert_contains "$out" "cannot bind http://127.0.0.1:$port/" "taken-port failure did not name the loopback URL"
  pass "dashboard fails loudly when the port is taken"
}

test_renders_fixture_snapshot
test_binds_loopback
test_taken_port_fails_loudly
