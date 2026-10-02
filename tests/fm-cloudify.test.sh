#!/usr/bin/env bash
# Behavior tests for bin/fm-cloudify.sh and bin/fm-bare-metal.sh - moving a
# task's execution between its local worker and a Cursor Cloud agent.
#
# Hermetic: real throwaway git repos with a real bare origin, a fake `curl` that
# answers the Cloud Agents API from fixtures, and a fake `tmux` so the live-window
# check resolves. Nothing reaches api.cursor.com and no real key is needed.
#
# The refusals matter more than the happy paths here: cloudifying a worktree that
# holds uncommitted or unpushed work destroys that work, and returning a diverged
# branch would discard the cloud agent's commits.
#
# Cases:
#   (a) preflight refuses, naming the exact condition, for: unknown task, a task
#       already in the cloud, a dead window, a detached HEAD, no upstream,
#       uncommitted changes, and unpushed commits
#   (b) a missing handoff is a refusal, so "the worker wrote its handoff" is
#       enforced rather than assumed
#   (c) a successful cloudify records location=cloud and cursor_agent=, arms a
#       registered check, and sends workOnCurrentBranch with a checkout
#       instruction for the WORKTREE's branch
#   (d) the create prompt carries the handoff and never enumerates repos
#   (e) --all reports each refusal individually and still migrates the others
#   (f) bare-metal refuses a local task, and refuses while a run is active unless
#       --cancel-active is given
#   (g) bare-metal captures the cloud agent's result as the return handoff BEFORE
#       archiving, fast-forwards the worktree, archives, and disarms the check
#   (h) bare-metal refuses a divergence rather than forcing
#   (i) the return path uses the WORKTREE's branch, never the API's reported one
#   (j) a branch pushed WITHOUT -u has no tracking ref but is still published;
#       preflight must accept it and must still catch an unpushed commit on it
#   (k) a branch on no remote at all is still refused, with the same wording
#   (l) resolving the remote ref never writes tracking config or adds a remote
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLOUDIFY="$ROOT/bin/fm-cloudify.sh"
BAREMETAL="$ROOT/bin/fm-bare-metal.sh"
TMP_ROOT=$(fm_test_tmproot fm-cloudify)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_git_identity fmtest fmtest@example.invalid

KEY=key_cloudifytest
FIXTURES="$TMP_ROOT/fixtures"
CALLS="$TMP_ROOT/calls"
BODIES="$TMP_ROOT/bodies"
mkdir -p "$FIXTURES"
export FM_CURSOR_TEST_FIXTURES="$FIXTURES" FM_CURSOR_TEST_KEY="$KEY"
export FM_CURSOR_TEST_CALLS="$CALLS" FM_CURSOR_TEST_BODIES="$BODIES"
export FM_CURSOR_TEST_VIOLATIONS="$TMP_ROOT/violations" FM_CURSOR_TEST_CFGS="$TMP_ROOT/cfgs"

# Fake curl: same shape as tests/fm-cursor.test.sh's, trimmed to what these
# cases need.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=; url=; method=GET; data=
while [ "$#" -gt 0 ]; do
  case $1 in
    --config) shift 2 ;;
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    -X) method=$2; shift 2 ;;
    -H) shift 2 ;;
    --data-binary) data=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$FM_CURSOR_TEST_CALLS"
if [ -n "$data" ]; then
  case $data in
    @*) cat "${data#@}" >> "$FM_CURSOR_TEST_BODIES" 2>/dev/null || true ;;
    *) printf '%s' "$data" >> "$FM_CURSOR_TEST_BODIES" ;;
  esac
  printf '\n' >> "$FM_CURSOR_TEST_BODIES"
fi
slug=$(printf '%s' "${url#*://}" | sed 's/[^A-Za-z0-9]/_/g')
body="$FM_CURSOR_TEST_FIXTURES/${method}_$slug.json"
[ -f "$body" ] || body="$FM_CURSOR_TEST_FIXTURES/$slug.json"
code=200
if [ -f "$body" ]; then
  [ -z "$out" ] || cp "$body" "$out"
else
  [ -z "$out" ] || printf '{"message":"no fixture for %s"}' "$slug" > "$out"
  code=404
fi
printf '%s' "$code"
SH
chmod +x "$FAKEBIN/curl"

# Fake tmux so fm_backend_target_exists resolves. The adapter checks the EXIT
# STATUS of `tmux display-message -p -t <target>`, so this must fail for a window
# that is not live rather than printing an empty string and succeeding.
# LIVE_WINDOWS lists what exists; emptying it simulates a dead pane.
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
sub=${1:-}
target=
prev=
for a in "$@"; do
  [ "$prev" != -t ] || target=$a
  prev=$a
done
case $sub in
  display-message)
    [ -n "${LIVE_WINDOWS:-}" ] || exit 1
    case " $LIVE_WINDOWS " in
      *" $target "*) printf '%%0\n'; exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  list-panes|list-windows)
    [ -z "${LIVE_WINDOWS:-}" ] || printf '%s\n' "$LIVE_WINDOWS"
    ;;
  *) : ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

fixture() {  # <url-path> <json>
  local slug; slug=$(printf '%s' "api.cursor.com$1" | sed 's/[^A-Za-z0-9]/_/g')
  printf '%s' "$2" > "$FIXTURES/$slug.json"
}
fixture_post() {  # <url-path> <json>
  local slug; slug=$(printf '%s' "api.cursor.com$1" | sed 's/[^A-Za-z0-9]/_/g')
  printf '%s' "$2" > "$FIXTURES/POST_$slug.json"
}

# A home with one task whose worktree is a real branch tracking a real origin.
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
printf 'CURSOR_API_KEY=%s\n' "$KEY" > "$HOME_DIR/.env"
printf 'AgentScan E2E\n' > "$HOME_DIR/config/cursor-environment"

REPO="$TMP_ROOT/repo"
WT="$TMP_ROOT/wt-t1"
BARE="$REPO.origin.git"
fm_git_worktree "$REPO" "$WT" fm/t1
git -C "$WT" push --quiet -u origin fm/t1

fm_write_meta "$HOME_DIR/state/t1.meta" \
  "window=firstmate:fm-t1" "endpoint_task_id=t1" "worktree=$WT" \
  "project=$REPO" "harness=claude" "kind=ship" "mode=direct-PR" "yolo=on"
mkdir -p "$HOME_DIR/data/t1"
printf '# Handoff\n\nHalf done. Rejected the sync approach because it deadlocks.\n' \
  > "$HOME_DIR/data/t1/handoff.md"

RC=0
OUT=
run_cloudify() {
  : > "$CALLS"; : > "$BODIES"
  set +e
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    LIVE_WINDOWS="firstmate:fm-t1 firstmate:fm-t2 firstmate:fm-t3" \
    FM_CURSOR_API_BASE="https://api.cursor.com" "$CLOUDIFY" "$@" 2>&1)
  RC=$?
  set -e
}
run_bare_metal() {
  : > "$CALLS"; : > "$BODIES"
  set +e
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" LIVE_WINDOWS="firstmate:fm-t1" \
    FM_CURSOR_API_BASE="https://api.cursor.com" "$BAREMETAL" "$@" 2>&1)
  RC=$?
  set -e
}

# --- (a) preflight refusals --------------------------------------------------

run_cloudify nosuchtask
expect_code 4 "$RC" "an unknown task is refused"
assert_contains "$OUT" "no such task" "the refusal names the missing task"

# A dead window: the task keeps its window in both modes, so without one there is
# nothing to hand back to.
set +e
OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" LIVE_WINDOWS="" \
  FM_CURSOR_API_BASE="https://api.cursor.com" "$CLOUDIFY" t1 2>&1)
RC=$?
set -e
expect_code 4 "$RC" "a task with no live window is refused"
assert_contains "$OUT" "no live window" "the refusal names the dead window"

printf 'scratch\n' > "$WT/dirty.txt"
run_cloudify t1
expect_code 4 "$RC" "uncommitted changes are refused"
assert_contains "$OUT" "uncommitted changes" "the refusal names uncommitted work"
assert_contains "$OUT" "or they are lost" "the refusal says why it matters"
rm -f "$WT/dirty.txt"

git -C "$WT" -c user.name=t -c user.email=t@e commit -qm "unpushed" --allow-empty
run_cloudify t1
expect_code 4 "$RC" "unpushed commits are refused"
assert_contains "$OUT" "ahead of" "the refusal says the branch is ahead"
git -C "$WT" push --quiet origin fm/t1

pass "preflight refuses uncommitted and unpushed work, a dead window, and an unknown task"

# --- (b) a missing handoff is a refusal --------------------------------------

mv "$HOME_DIR/data/t1/handoff.md" "$HOME_DIR/data/t1/handoff.md.bak"
run_cloudify t1
expect_code 4 "$RC" "a missing handoff is refused"
assert_contains "$OUT" "no handoff" "the refusal names the missing handoff"
assert_no_grep "POST" "$CALLS" "a refused cloudify creates no agent"
mv "$HOME_DIR/data/t1/handoff.md.bak" "$HOME_DIR/data/t1/handoff.md"
pass "a cloudify without a handoff is refused before any agent is created"

# --- (c)(d) a successful cloudify --------------------------------------------

fixture_post "/v1/agents" \
  '{"agent":{"id":"bc-cloud111","status":"ACTIVE","url":"https://cursor.com/agents/bc-cloud111","env":{"type":"cloud","name":"AgentScan E2E"}},"run":{"id":"run-c1","status":"CREATING"}}'

run_cloudify t1
expect_code 0 "$RC" "a clean task cloudifies"
assert_contains "$OUT" "bc-cloud111" "the new agent id is reported"
assert_grep "POST https://api.cursor.com/v1/agents" "$CALLS" "cloudify creates an agent"

assert_grep "location=cloud" "$HOME_DIR/state/t1.meta" "location is recorded as cloud"
assert_grep "cursor_agent=bc-cloud111" "$HOME_DIR/state/t1.meta" "the agent link is recorded"
assert_grep "window=firstmate:fm-t1" "$HOME_DIR/state/t1.meta" \
  "the task KEEPS its window, so nothing becomes windowless"
assert_grep "worktree=$WT" "$HOME_DIR/state/t1.meta" "the task keeps its worktree"

assert_present "$HOME_DIR/state/t1.check.sh" "a poll is armed"
assert_present "$HOME_DIR/state/t1.check-trust" "the poll is registered, not just written"
perms=$(stat -f '%Lp' "$HOME_DIR/state/t1.check.sh" 2>/dev/null || stat -c '%a' "$HOME_DIR/state/t1.check.sh")
[ "$perms" = 700 ] || fail "the armed check must be mode 0700, got $perms"

jq -e '.workOnCurrentBranch == true' "$BODIES" >/dev/null \
  || fail "cloudify must send workOnCurrentBranch: $(cat "$BODIES")"
jq -e '.env.name == "AgentScan E2E"' "$BODIES" >/dev/null \
  || fail "cloudify must name the environment from config/cursor-environment"
jq -e 'has("repos") | not' "$BODIES" >/dev/null \
  || fail "cloudify must never enumerate repos - the environment carries the secrets"
jq -e '.prompt.text | contains("git checkout fm/t1")' "$BODIES" >/dev/null \
  || fail "the prompt must instruct a checkout of the WORKTREE's branch"
jq -e '.prompt.text | contains("Rejected the sync approach")' "$BODIES" >/dev/null \
  || fail "the prompt must carry the worker's handoff"
pass "cloudify records the link, keeps the window, arms a registered poll, and sends the handoff"

run_cloudify t1
expect_code 4 "$RC" "cloudifying an already-cloud task is refused"
assert_contains "$OUT" "already location=cloud" "the refusal names the current location"
pass "a task already in the cloud is refused rather than migrated twice"

# --- (f) bare-metal refusals -------------------------------------------------

fixture "/v1/agents/bc-cloud111/runs?limit=1" \
  '{"items":[{"id":"run-c1","status":"RUNNING","createdAt":"2026-08-01T10:00:00.000Z","durationMs":null,"git":{"branches":[{"repoUrl":"github.com/x/y","branch":"main"}]}}]}'
run_bare_metal t1
expect_code 4 "$RC" "an active run is refused"
assert_contains "$OUT" "cloud run is RUNNING" "the refusal names the run state"
assert_contains "$OUT" "--cancel-active" "the refusal names the explicit override"
assert_absent "$HOME_DIR/data/t1/handoff-return.md" "a refused return writes no return handoff"
pass "bare-metal never silently interrupts a running cloud agent"

# --- (g) a successful return -------------------------------------------------
#
# The cloud agent's commit is simulated by pushing to the bare origin from a
# separate clone, exactly as a cloud agent would.
CLOUD_CLONE="$TMP_ROOT/cloudclone"
git clone --quiet "$BARE" "$CLOUD_CLONE"
git -C "$CLOUD_CLONE" checkout -q fm/t1
printf 'cloud work\n' > "$CLOUD_CLONE/from-cloud.txt"
git -C "$CLOUD_CLONE" add from-cloud.txt
git -C "$CLOUD_CLONE" -c user.name=c -c user.email=c@e commit -qm "cloud: did the work"
git -C "$CLOUD_CLONE" push --quiet origin fm/t1

# The API reports `main` here on purpose: that is the live misreport this design
# must not trust. The return must still fast-forward fm/t1.
# The list item carries NO `result`, which is what the live API actually returns -
# verified 2026-08-01 - while the individual run carries it populated. The return
# handoff is the only record of the cloud agent's reasoning, so a fixture that put
# the result in the list item would let an empty handoff pass as correct.
fixture "/v1/agents/bc-cloud111/runs?limit=1" \
  '{"items":[{"id":"run-c1","status":"FINISHED","createdAt":"2026-08-01T10:00:00.000Z","durationMs":5000,"git":{"branches":[{"repoUrl":"github.com/x/y","branch":"main"}]}}]}'
fixture "/v1/agents/bc-cloud111/runs/run-c1" \
  '{"id":"run-c1","status":"FINISHED","createdAt":"2026-08-01T10:00:00.000Z","durationMs":5000,"result":"I implemented the retry and rejected the queue approach because it reordered events.","git":{"branches":[{"repoUrl":"github.com/x/y","branch":"main"}]}}'
fixture_post "/v1/agents/bc-cloud111/archive" '{"ok":true}'

before=$(git -C "$WT" rev-parse HEAD)
run_bare_metal t1
expect_code 0 "$RC" "a finished cloud task returns"
after=$(git -C "$WT" rev-parse HEAD)
[ "$before" != "$after" ] || fail "the worktree should have fast-forwarded onto the cloud agent's commit"
[ -f "$WT/from-cloud.txt" ] || fail "the cloud agent's file should be present after the fast-forward"
assert_grep "location=local" "$HOME_DIR/state/t1.meta" "location returns to local"
assert_grep "cursor_agent=bc-cloud111" "$HOME_DIR/state/t1.meta" \
  "cursor_agent is RETAINED for provenance"
assert_present "$HOME_DIR/data/t1/handoff-return.md" "the return handoff is written"
assert_grep "rejected the queue approach" "$HOME_DIR/data/t1/handoff-return.md" \
  "the return handoff carries the cloud agent's reasoning"
assert_absent "$HOME_DIR/state/t1.check.sh" "the poll is disarmed"
assert_absent "$HOME_DIR/state/t1.check-trust" "the poll registration is removed"
assert_grep "POST https://api.cursor.com/v1/agents/bc-cloud111/archive" "$CALLS" \
  "the cloud agent is archived, never deleted"
assert_no_grep "DELETE" "$CALLS" "bare-metal must never issue a DELETE"
pass "bare-metal captures the return handoff, fast-forwards, archives, and disarms the poll"

# --- (i) the branch came from the worktree, not the API ----------------------
#
# Every fixture above reports branch "main" while the work is on fm/t1, which is
# the live misreport this design must not trust.
#
# Two independent guarantees, and it is worth being precise about which is which.
# The fast-forward itself targets `@{upstream}` of the checked-out HEAD, so it is
# structurally incapable of following the API's value - that is why the file
# assertion below passes even if someone rewires `branch`. What DOES depend on
# reading the worktree is everything that names the branch: the detached-HEAD
# refusal and every reported line. So assert the reported branch too, or a
# regression that starts trusting the API would slip through silently.
[ -f "$WT/from-cloud.txt" ] || fail "the return must land the cloud agent's commit on the worktree's branch"
[ "$(git -C "$WT" symbolic-ref --short HEAD)" = fm/t1 ] || fail "the worktree should still be on fm/t1"
assert_contains "$OUT" "fm/t1" "the return must report the WORKTREE's branch"
assert_not_contains "$OUT" "main is at" "the return must never report the API's misreported branch"
pass "the return path follows and reports the worktree's branch even when the API says main"

run_bare_metal t1
expect_code 4 "$RC" "returning an already-local task is refused"
assert_contains "$OUT" "not cloud" "the refusal names the location"

# --- (h) divergence is refused, not forced -----------------------------------

# Put the task back in the cloud, then diverge: local gains a commit the remote
# does not have while the remote has moved on too.
sed -i.bak 's/^location=local$/location=cloud/' "$HOME_DIR/state/t1.meta"
rm -f "$HOME_DIR/state/t1.meta.bak"
git -C "$WT" -c user.name=l -c user.email=l@e commit -qm "local divergent" --allow-empty
printf 'more cloud\n' > "$CLOUD_CLONE/from-cloud2.txt"
git -C "$CLOUD_CLONE" add from-cloud2.txt
git -C "$CLOUD_CLONE" -c user.name=c -c user.email=c@e commit -qm "cloud: more"
git -C "$CLOUD_CLONE" push --quiet origin fm/t1

run_bare_metal t1
expect_code 4 "$RC" "a divergence is refused"
assert_contains "$OUT" "divergence" "the refusal names the divergence"
assert_contains "$OUT" "real work" "the refusal says the cloud commits matter"
assert_no_grep "archive" "$CALLS" "a refused return must not archive the agent"
pass "bare-metal refuses a divergence rather than forcing over the cloud agent's commits"

# --- (j) a branch pushed without -u is still published -----------------------
#
# `git push <remote> <branch>` publishes the branch and updates
# refs/remotes/<remote>/<branch> while setting NO tracking configuration. Reading
# only @{upstream} therefore refused branches that were demonstrably on their
# remote - in the live fleet that included a branch carrying an open pull
# request. These use their own fixtures so t1's mutated end state cannot mask the
# result.

REPO2="$TMP_ROOT/repo2"; WT2="$TMP_ROOT/wt-t2"; BARE2="$REPO2.origin.git"
fm_git_worktree "$REPO2" "$WT2" fm/t2
# Deliberately WITHOUT -u: this is the state the defect mishandled.
git -C "$WT2" push --quiet origin fm/t2
[ -z "$(git -C "$WT2" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)" ] \
  || fail "fixture t2 must have no tracking ref, or it does not exercise the defect"
git -C "$WT2" rev-parse --verify --quiet refs/remotes/origin/fm/t2 >/dev/null \
  || fail "fixture t2 must still have a remote-tracking ref from the push"
fm_write_meta "$HOME_DIR/state/t2.meta" \
  "window=firstmate:fm-t2" "endpoint_task_id=t2" "worktree=$WT2" \
  "project=$REPO2" "harness=claude" "kind=ship" "mode=direct-PR" "yolo=on"
mkdir -p "$HOME_DIR/data/t2"
printf '# Handoff\n\nt2 context.\n' > "$HOME_DIR/data/t2/handoff.md"

run_cloudify t2 --dry-run
expect_code 0 "$RC" "a branch pushed without -u must pass preflight"
assert_contains "$OUT" "would cloudify t2" "the published branch is accepted"
assert_not_contains "$OUT" "no upstream remote" "a pushed branch must not be called unpublished"
pass "a branch published without -u is recognised as published"

# The not-ahead check must use that same remote ref, not silently skip.
git -C "$WT2" -c user.name=t -c user.email=t@e commit -qm "unpushed on t2" --allow-empty
run_cloudify t2 --dry-run
expect_code 4 "$RC" "an unpushed commit on an untracked branch is still refused"
assert_contains "$OUT" "ahead of" "the ahead check runs against the resolved remote ref"
assert_contains "$OUT" "origin/fm/t2" "the refusal names the ref it compared against"
git -C "$WT2" push --quiet origin fm/t2
pass "the not-ahead check compares against the resolved remote ref"

# --- (k) a branch on no remote is still refused, unchanged -------------------

REPO3="$TMP_ROOT/repo3"; WT3="$TMP_ROOT/wt-t3"
fm_git_worktree "$REPO3" "$WT3" fm/t3
fm_write_meta "$HOME_DIR/state/t3.meta" \
  "window=firstmate:fm-t3" "endpoint_task_id=t3" "worktree=$WT3" \
  "project=$REPO3" "harness=claude" "kind=ship" "mode=direct-PR" "yolo=on"
mkdir -p "$HOME_DIR/data/t3"
printf '# Handoff\n\nt3 context.\n' > "$HOME_DIR/data/t3/handoff.md"

run_cloudify t3 --dry-run
expect_code 4 "$RC" "a branch on no remote is refused"
assert_contains "$OUT" "has no upstream remote, so the cloud agent cannot fetch it" \
  "the genuine refusal keeps its original wording"
pass "a branch that is truly on no remote is still refused, with the same wording"

# --- (l) preflight never mutates the repository ------------------------------
#
# Resolving a remote ref must not be achieved by setting one.
[ -z "$(git -C "$WT2" config --get branch.fm/t2.remote || true)" ] \
  || fail "preflight must not write tracking config"
[ -z "$(git -C "$WT2" config --get branch.fm/t2.merge || true)" ] \
  || fail "preflight must not write tracking config"
[ -z "$(git -C "$WT3" config --get branch.fm/t3.remote || true)" ] \
  || fail "preflight must not add a remote to reach a verdict"
pass "preflight resolves the remote ref read-only, setting no upstream"

printf '\nall fm-cloudify tests passed\n'
