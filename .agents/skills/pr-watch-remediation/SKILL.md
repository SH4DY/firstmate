---
name: pr-watch-remediation
description: >-
  Agent-only response procedure for GitHub PR monitor notifications that report a branch behind
  its base or a failed required CI check.
user-invocable: false
metadata:
  internal: true
---

# pr-watch-remediation

Use this skill only for a GitHub PR monitor notification whose result is `behind <head>` or `ci-failed <head> <check-fingerprint>`.
The monitor has already deduplicated that exact PR URL, head, and condition.
Reconcile the task's current PR identity and worker state before acting because the notification is not current state.

The actions below operate on a project's remote pull request or its worker endpoint, not on project files.
Hard rule 1's project-write ban therefore does not apply.
They do not authorize force-pushes, conflict resolution, merges, project-file edits by firstmate, or any destructive action.

## Branch behind

Use `gh-axi pr update-branch <number>` for the recorded GitHub PR without `--rebase`.
GitHub documents that default as merging the base branch into the PR branch, so it does not rewrite history.
If it succeeds, resume normal supervision without reporting routine progress.
If it fails, stop instead of retrying, forcing, or resolving a conflict blind.
Escalate to the captain with the failure and that the branch likely needs a manual conflict resolution.

## Required CI failure

First identify the current failed required job from the GitHub PR and read its failed-job log before deciding on a repair.
Confirm that the task's worker is alive through the recorded endpoint.
If it is not alive, escalate with the failed-job evidence rather than attempting a repair without its worker.

Before each automatic repair, use `bin/fm-pr-ci-fix-count.sh claim <task-id> <github-pr-url>`.
That helper records the PR identity and count atomically, allows two cycles total for the same PR, and returns `exhausted: 2` when both cycles are already claimed.
On a claim, steer the same alive worker with the specific failed-job evidence and one concise instruction to fix the CI failure, commit, push, and let CI rerun.
Do not edit, commit, or push project files yourself.
If the count is exhausted, the log does not identify an actionable repair, or steering fails, escalate to the captain.

Do not treat a running or non-required check as a failure.
Do not reset the count after a restart, a new head, or a different failing check.
