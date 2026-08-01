---
name: firstmate-cursor-cloud
description: >-
  Agent-only playbook for reading, steering, and creating the captain's own Cursor Cloud agents without pretending they are a selectable runtime backend or a harness.
  Use before reporting on Cursor Cloud agent activity, before answering what a cloud agent is doing or concluded, before sending a follow-up to or cancelling, archiving, or creating a cloud agent, and before responding to requests to make Cursor Cloud native to firstmate.
user-invocable: false
metadata:
  internal: true
---

# firstmate-cursor-cloud

## Overview

Use this playbook when the captain asks what his Cursor Cloud agents are doing, what one of them concluded, or what they have consumed.
The supported shape is `bin/fm-cursor.sh`, not a `cursor` value in `FM_BACKEND` and not an eighth harness.
It reads the fleet with `list`, `show`, `runs`, and `usage`, and changes it with `send`, `cancel`, `archive`, `unarchive`, and `create`.

`bin/fm-cursor.sh --help` owns the exact subcommands, flags, environment variables, and exit codes.
[`docs/configuration.md`](../../../docs/configuration.md) owns the `.env` activation contract.
This skill owns only the judgment: what the numbers mean, what this surface cannot do, and how to report it.

## Boundary

Cursor Cloud agents are a companion surface, the same boundary [`firstmate-codexapp`](../firstmate-codexapp/SKILL.md) draws for Codex Desktop threads.
They are not a runtime backend and not a harness, for concrete reasons rather than taste.

- A runtime backend must supply bounded pane capture, a composer, special-key sends, and a local worktree path.
  A cloud agent has none of these, so most of the adapter contract in `bin/fm-backend.sh` could only be stubbed with lies.
- A harness is a local interactive CLI that `bin/fm-spawn.sh` launches into a pane and `bin/fm-harness.sh` detects in the process tree.
  A cloud agent has no local process at all.
- A ship spawn must pass the worktree-isolation assertion in `bin/fm-spawn.sh`, which no cloud agent can satisfy.
  Bypassing that assertion for a whole backend class would weaken a safety invariant to fit a remote executor.

If the captain asks to make Cursor Cloud a native backend, relay that boundary and the increment path below rather than inventing an adapter.

## The one fact that is easy to get wrong

An agent's `status` field is lifecycle only: the enum is `ACTIVE|ARCHIVED`, and Cursor documents execution status as living on runs instead.
`ACTIVE` means "not archived". It does not mean the agent is working.
A finished agent stays `ACTIVE` indefinitely until somebody archives it, so a fleet of thirty `ACTIVE` agents can have nothing running at all.

Never report agent lifecycle as though it were activity.
Take the run status from the latest run, which `bin/fm-cursor.sh list` resolves and reports as its primary column: `CREATING` and `RUNNING` mean work is in flight, and `FINISHED`, `ERROR`, `CANCELLED`, and `EXPIRED` are terminal.

That enum is not the whole column, and the two values outside it are the ones most likely to be misread.
`unknown` is a third category that is neither in flight nor terminal: it means resolving that agent's latest run failed, so its real state was never observed.
`unresolved` is the same absence by choice rather than by failure, and appears only under `--no-runs`, which skips resolution entirely.
Never read either value as idle, finished, or terminal, and never fold an `unknown` row into a "nothing running" count.
The honest report is "could not tell for that agent, and here is why", because guessing at an unobserved state is the same fleet misread this whole environment-and-run-status design exists to prevent.
Only the affected rows degrade: every other row in the same listing was resolved normally.
`list` prints the reasons grouped under its unresolved count, and `--json` carries each one in `runStatusReason` alongside a `runStatusSource` of `resolution-failed`, which distinguishes a failed resolution from the `latestRunId` fast path, the `runs-list` fallback, and the `skipped` case under `--no-runs`.
A rate limit and a rejected key therefore read differently, so use the reason rather than retrying blind.

## Reading the fleet

1. `bin/fm-cursor.sh list` for the current picture, or `--json` when you need to compute over it.
2. `bin/fm-cursor.sh show <agent-id>` for one agent's repositories, environment, and Cursor Web URL.
3. `bin/fm-cursor.sh runs <agent-id>` for its history, including any PR URL a run produced.
4. `bin/fm-cursor.sh usage <agent-id>` for token consumption.

Two properties of the data change how you read it.

**The environment is the unit of work, not the repository.**
A Cursor agent is the task and its environment is the project: a named, multi-repo, secret-bearing context that `POST /v1/agents` accepts instead of a bare repository list, the two being mutually exclusive in the API.
A change spanning a front end and a back end is therefore one agent in one environment, not several tasks, and there is no multi-repo case to restrict.
`list` and `show` lead with the environment name for that reason.
Never describe an agent as working "in maverick-ui" when it runs in an environment that contains maverick-ui; name the environment.
Never assume a run's PR URL belongs to any particular repository in that environment - take the URL as given.
An agent created from a bare repository list has no environment name and displays as ad-hoc; it also carries none of a named environment's predefined secrets, which is worth saying when a captain wonders why an ad-hoc agent behaved differently from one in the shared environment.

**This home may declare a default environment** in `config/cursor-environment`, which `list` marks with `*` and `show` calls out.
The default is the intended target for a future operation that needs an environment; it deliberately does not filter what `list` shows, because hiding the agents outside it would misrepresent the fleet.
Use `--env` to narrow to the default or `--env <name>` for another environment, and read the filtered footer, which reports matches against the fetched page rather than against the whole fleet.
When the captain asks about "the environment" without naming one, the configured default is the sensible referent; say which one you used.

Run status resolution prefers a `latestRunId` field that list items carry in practice but that is **not** in Cursor's published schema, falling back to a per-agent runs lookup.
`--json` records which source answered in `runStatusSource`.
If the fast path ever disappears the fallback keeps working, so treat a change there as a Cursor-side change rather than a firstmate defect.
The fallback is always attempted when the fast path fails, and neither `list` nor `show` aborts when both fail: a stale run id says nothing about the agent, which the helper has usually just fetched successfully, so the run alone degrades to `unknown` with its reason.

## Changing the fleet

These verbs act on real agents that cost real quota, so treat them as you would any other outward-facing action.

- `send <agent-id> <text>` queues a follow-up run. `cancel <agent-id>` stops the active one.
- `archive <agent-id>` is the cleanup verb and `unarchive` reverses it.
- `create [--env <name>] --prompt <text>` starts a new agent, defaulting the environment to `config/cursor-environment`.

Three rules are built into the helper and worth understanding rather than rediscovering.

Only one run can be active per agent, so `send`, `cancel`, and `archive` read the latest run status first and refuse rather than firing a request the API would reject with `409 agent_busy`.
An indeterminate run state is also a refusal: the helper will not risk interrupting live work it cannot see.
Report a refusal as the concrete situation - that agent is still working - rather than as a tool error.

A follow-up never sends `mcpServers`, because the API documents follow-up definitions as *replacing* the agent's create-time set.
Passing them would silently strip the agent's tools mid-conversation with no error, so if anyone proposes adding that field, the answer is no unless the operator is deliberately overriding the set for one run.

`create` names the environment and never enumerates repositories.
The two are mutually exclusive in the API, and the environment carries the predefined secrets and MCP configuration, so building an agent by listing an environment's repositories yields one that looks correct and cannot authenticate.

Every mutating verb needs an explicit agent id. There is no most-recent default and no wildcard, because steering the wrong agent is not undone by re-running the command.

## Moving a task between local and cloud

`/cloudify` moves a task's execution to a Cursor Cloud agent; `/bare-metal` brings it back.
`bin/fm-cloudify.sh --help` and `bin/fm-bare-metal.sh --help` own the exact flags.

The task keeps its identity, its `state/<id>.meta`, its status file **and its window** in both modes.
Only where the work executes moves, so the worker in the pane becomes a waiter exactly as it already is while a no-mistakes run's separate agent process does the work.
Nothing becomes windowless, which is why session start, `bin/fm-crew-state.sh` and `stuck-crewmate-recovery` need no exemption for a cloudified task.
`location=local|cloud` and `cursor_agent=` are the only new meta fields, and `cursor_agent` is retained after returning so the agent that did the work stays discoverable.

**Your part is the judgment; the scripts own the mechanics.**
Before running `/cloudify`, tell the worker to commit everything, push, and write its handoff to `data/<id>/handoff.md`, then wait for it.
`bin/fm-cloudify.sh` refuses without that file, so the handoff cannot be skipped, but it cannot write the handoff for you.
After `/cloudify` succeeds, tell the worker it is now a waiter: stop working, do not touch the branch, remain available.
After `/bare-metal`, hand the worker `data/<id>/handoff-return.md` and tell it to resume.

**The handoff is the point of the whole feature**, so do not let the worker write a diff summary.
It must carry what git cannot: where the work actually stands, what was tried and *rejected and why*, landmines that look wrong but are deliberate, environment facts learned the hard way, the exact commands that verify the work, and any open question or captain hold.
Without the rejected-approaches section the receiving agent walks the same dead ends, which is the expensive failure this is designed to prevent.

**Preflight refuses rather than half-migrating**, naming the exact condition: the task must exist, be local, have a live window, sit on a branch with an upstream, and have nothing uncommitted and nothing unpushed.
The last two are hard rule 3 territory and have no `--force`: cloudifying either destroys that work, because the cloud agent starts from what the remote has.
When a refusal names uncommitted or unpushed work, the fix is to have the worker commit and push, never to override.

`--all` reports each refusal individually and still migrates the rest, so relay which tasks were skipped and why rather than a single pass/fail.

On the return, `/bare-metal` refuses while a cloud run is still active unless explicitly told to cancel, captures the agent's final text as the return handoff *before* archiving anything, fast-forwards the worktree, and refuses a divergence rather than forcing over the cloud agent's commits.
A divergence means both sides moved and it needs a human; treat it as real work at risk, not a glitch.

## What this surface cannot do

- **It cannot delete.** `DELETE /v1/agents/{id}` is deliberately never wired, because it is permanent.
  `archive` is the cleanup verb and `unarchive` reverses it, so prefer archiving and say so rather than reaching for a destructive path that does not exist here.
- **It cannot show a live run's progress.** The Cloud Agents API has no conversation or messages endpoint, so there is no cheap bounded read of an in-flight run.
  A terminal run's final text is available through the API; for anything mid-run, escalate the URL rather than guessing.
- **It cannot report money.** `usage` returns token counts only, because the Cloud Agents API exposes no price or charge field.
  Report tokens and run counts, say that cost is unavailable, and never estimate spend from token counts and a public price list.
- **It sees only this operator's own agents.** A user API key is scoped to its own user, so this is not a company-wide fleet view.
  `GET /v1/agents` is documented as listing agents for the authenticated user and offers no team or user filter.
  Team-wide visibility would need a service account key that only a Cursor team admin can create, and it is not established that such a key enumerates agents created by other people rather than only its own.
  Do not promise a fleet-wide view on that basis; say what this key can see.

## Reporting to the captain

Translate through `AGENTS.md` section 9 as usual, and prefer the captain's nouns: the cloud agent, the run, the pull request, the repository.
Report activity from run status, never from lifecycle, and say "nothing running" rather than "35 active" when that is what the data means.
Include the full Cursor Web URL when the captain will want to open the agent, exactly as PR URLs are always given in full.

## Failure signals

- Helper reports it is not configured: the home has no `CURSOR_API_KEY` in its `.env`. Relay that and the dashboard link; do not go looking for a key in a keychain or another tool's credential store.
- Helper reports the key was rejected: the key is wrong, revoked, or belongs to another account. Ask the captain to regenerate it; never fall back to another credential source.
- Helper reports rate limiting: back off rather than retrying in a loop, and prefer `--limit` or `--no-runs` to shrink the request count.
- Helper reports `RUN` unknown for some rows: read the grouped reasons printed under that count, because they say whether Cursor throttled the run lookups, rejected the key, or no longer has those runs. Report which it was, and never present those rows as idle.
- Every listed agent reads terminal but the captain expects work in flight: check whether he is looking at a different Cursor account, since this view is per-user.
