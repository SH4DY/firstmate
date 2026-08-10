#!/usr/bin/env bash
# Behavioral tests for the durable two-cycle automatic CI repair counter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COUNTER="$ROOT/bin/fm-pr-ci-fix-count.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-ci-fix-count)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
URL_ONE=https://github.com/example/repository/pull/9
URL_TWO=https://github.com/example/repository/pull/10
mkdir -p "$STATE"

run_counter() {
  FM_HOME="$HOME_DIR" "$COUNTER" "$@"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

test_claim_persists_two_cycles_per_pr() {
  local out rc count
  out=$(run_counter get task-a "$URL_ONE") || fail "fresh counter read failed"
  [ "$out" = 0 ] || fail "fresh counter did not start at zero"

  out=$(run_counter claim task-a "$URL_ONE") || fail "first CI repair claim failed"
  [ "$out" = 'claimed: 1' ] || fail "first CI repair claim did not report one"
  out=$(run_counter claim task-a "$URL_ONE") || fail "second CI repair claim failed"
  [ "$out" = 'claimed: 2' ] || fail "second CI repair claim did not report two"

  set +e
  out=$(run_counter claim task-a "$URL_ONE")
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "third CI repair claim did not exhaust the durable limit"
  [ "$out" = 'exhausted: 2' ] || fail "exhausted CI repair claim did not report its limit"

  count=$(run_counter get task-a "$URL_ONE") || fail "persisted counter read failed"
  [ "$count" = 2 ] || fail "persisted counter reset after a new process"
  [ "$(file_mode "$STATE/task-a.pr-ci-fix-count")" = 600 ] \
    || fail "durable counter is not private"
  pass "CI repair claims persist exactly two cycles for one pull request"
}

test_different_pr_resets_only_its_own_counter() {
  local out count
  out=$(run_counter claim task-a "$URL_TWO") || fail "different PR claim failed"
  [ "$out" = 'claimed: 1' ] || fail "different PR did not receive its own first claim"
  count=$(run_counter get task-a "$URL_ONE") || fail "original PR counter read failed"
  [ "$count" = 0 ] || fail "original PR count was not isolated after PR identity changed"
  pass "CI repair count keys the durable limit to the canonical pull request URL"
}

test_invalid_counter_refuses_claim() {
  local rc
  printf 'not-a-counter\n' > "$STATE/task-a.pr-ci-fix-count"
  chmod 0600 "$STATE/task-a.pr-ci-fix-count"
  set +e
  run_counter claim task-a "$URL_ONE" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "malformed counter authorized a CI repair"
  assert_grep 'CI fix count is unavailable' "$TMP_ROOT/err" \
    "malformed counter did not refuse safely"
  pass "malformed CI repair count refuses another automatic repair"
}

test_claim_persists_two_cycles_per_pr
test_different_pr_resets_only_its_own_counter
test_invalid_counter_refuses_claim
