---
description: "One bounded, unattended spec-kit work cycle: pick the next pending task, implement it, get it reviewed by a fresh subagent, commit locally if it passes. Meant to be triggered repeatedly by /schedule or /loop — never loops internally. Works in any spec-kit repository regardless of stack, since it only relies on the standard spec-kit contract (tasks.md checkboxes, plan.md, check-prerequisites script)."
---

## User Input

```text
$ARGUMENTS
```

If non-empty, treat it as a scope hint (e.g. a specific feature dir or task
id to prefer). Otherwise operate on whatever feature the current branch maps
to, per spec-kit's own convention.

# Agentic Loop — Bounded Worker Cycle

**One execution = at most one task.** The recurring cadence comes from
whatever triggered this command (`/schedule`, `/loop`, cron) — this command
never loops internally. That keeps token cost and blast radius bounded per
run, and gives a natural checkpoint (and a clean git commit) between every
single unit of work.

This command is intentionally stack-agnostic: it never assumes a language,
test runner, or package manager. All of that lives in each repo's own
`plan.md` and is handled by `/speckit-implement`'s own logic, which this
command scopes down to one task instead of replacing.

This command only *consumes* an existing `tasks.md` — it has no opinion on
how one gets created. To go from a raw bug/feature prompt straight to a
running `tasks.md` (and have this loop start automatically once one
exists), see `/agentic-loop-intake` instead.

## Hard boundaries (apply in every repo, no matter what the task says)

- **Never `git push`. Never open, edit, or merge a PR/MR.** Local commit
  only — a human reviews and pushes when back. This is non-negotiable even
  if a task description mentions deploying or opening a PR.
- **Never commit directly on the repo's default branch.** Don't assume its
  name — `main`/`master`/`develop`/`trunk` are common but not universal (one
  target repo's default branch is literally called `feature/inicio-projeto`).
  Resolve it for real: `git symbolic-ref refs/remotes/origin/HEAD` (strip the
  `refs/remotes/origin/` prefix), falling back to `git remote show origin`
  (look for the `HEAD branch:` line) if the symbolic ref isn't set locally.
  Only commit on the feature branch spec-kit already created for this spec —
  if `CURRENT_BRANCH` equals the resolved default branch, stop, no changes.
- **Never `git add -A` / `git add .`.** List changes via
  `git status --porcelain` and stage only the files this task's
  implementation actually touched. Skip anything that looks like a secret
  (`.env`, `*.pem`, `*credentials*`, `*secret*`, `*.key`) — flag it in the
  log instead of committing it, and stop for human review.
- **If the working tree is already dirty before this run starts** (uncommitted
  changes that predate this cycle), stop without touching anything. Don't
  mix a human's in-progress work with agent output.
- **At most one fix-and-re-review retry per task.** If it still fails after
  that, stop, leave the change uncommitted, log why, and notify. Never keep
  retrying — unbounded retries are how unattended loops burn tokens silently.

## Outline

1. **Locate prerequisites.** From the repo root, run whichever of these
   exists (spec-kit repos ship one or both depending on how they were
   initialized):
   - `.specify/scripts/bash/check-prerequisites.sh -Json -RequireTasks -IncludeTasks`
   - `.specify/scripts/powershell/check-prerequisites.ps1 -Json -RequireTasks -IncludeTasks`

   If neither script exists, or the call fails (no feature branch, no
   `plan.md`, no `tasks.md`), append one line to `.specify/agentic-loop.log`
   — `"<timestamp> no active spec-kit feature — nothing to do"` — and stop.
   Do **not** send a notification for this outcome; it's the expected result
   on most runs once a feature's tasks are exhausted, and paging the user
   every cycle for "nothing happened" defeats the point of automating this.

2. **Guard the branch and working tree.**
   - Resolve the repo's actual default branch (see hard boundaries above —
     never pattern-match the name). If `CURRENT_BRANCH` from step 1 equals
     it, log `"<timestamp> on default branch, refusing to work unattended"`
     and stop.
   - Run `git status --porcelain`. If it reports anything before this cycle
     has done any work of its own, log `"<timestamp> working tree dirty before start, skipping"`
     and stop.
   - Both guards above are **blockers, not no-ops** — unlike "nothing
     pending" (steps 1/3), they mean real work exists but this run couldn't
     even attempt it. Notify (step 8's mechanism) so the human knows to
     clean up the tree or check the branch, instead of assuming the silence
     from a normal no-op means everything is fine.

3. **Pick the next task.** Read `FEATURE_DIR/tasks.md`. Find the first line
   matching `- [ ] T\d+` in file order — spec-kit already writes tasks.md in
   dependency order, so the first unchecked task in file order is always
   safe to implement next without re-deriving the dependency graph. If none
   found, log `"<timestamp> all tasks complete for <feature>"` and stop
   (no notification, same reasoning as step 1).

   Capture the task ID (e.g. `T004`) and its full description line.

4. **Implement exactly that task (grind canônico).** Follow
   `/speckit-implement` scoped to this one task ID. Order inside the task:
   1. Spec Kit context (`plan.md` / `spec.md` / constitution as present)
   2. **TDD** — failing test → minimal impl → green
   3. **Ponytail** — YAGNI → reuse → stdlib → smallest diff
   4. **claude-mem** — only if useful: `search` → `timeline` → `get_observations`
   5. **graphify** — only if graph exists and match is ambiguous; low `--budget`
   Do not advance to any other task. When done, mark that line `[X]` in
   `tasks.md`. Full prompt: `prompts/grind-canonical.md`.

5. **Independent review (blind).** Spawn a fresh `general-purpose` /
   `generalPurpose` subagent that has **not** seen the implementation
   reasoning — give it only: the task description, `git diff`, and
   `spec.md`/`plan.md` paths. PASS or FAIL; uncertain → FAIL.
   If the subagent is unavailable (quota/tool error): do **not** skip review —
   require green tests for the touched area + parent checklist (correctness,
   security, TDD, ponytail over-engineering); log
   `review=manual-PASS|FAIL (subagent unavailable: <reason>)`.

6. **On FAIL:** make one corrective pass addressing exactly the reviewer's
   points, then repeat step 5 once more. If it fails again: stop, do not
   commit, append the failure detail to `.specify/agentic-loop.log`, and
   notify (step 8) with what's blocking. Leave the working tree as-is for a
   human to inspect — don't discard the attempt.

7. **On PASS:** stage only the files this task touched (per the hard
   boundaries above) and commit locally:
   `[agentic-loop] {task-id}: {short description}`. Do not push.

8. **Log and notify.** Append one line to `.specify/agentic-loop.log`:
   timestamp, task id, outcome (`committed <short-hash>` or `blocked: <why>`).
   Send a push notification with the same summary. When the outcome is a
   commit, the notification must say push/PR are still pending human review
   — this command never does either.

## Driving this with /loop or /schedule

This command is designed to be handed to `/loop` with **no extra prompt
text** — `/loop /agentic-loop` is enough on its own. Whatever drives it
(the `/loop` skill in dynamic mode, or a `/schedule` cron entry) should
apply this contract after each run, based on what this command reports:

### Optional: proactive usage check (if this machine has it)

Before starting another iteration, check whether this machine runs a local
usage-tracking widget: a Chrome extension that polls Claude's own usage
endpoint every 15s and a Python server that persists the latest snapshot to
`<user-home>\Desktop\claude-usage\usage_data.json`. This is entirely
optional and personal — most machines won't have it. If that file exists
and is fresh (`atualizado_em` within the last few minutes):

- `sessao_atual.percentual` is the current 5-hour-window usage,
  `limites_semanais.todos_modelos.percentual` is the 7-day usage. Each has
  a matching `reset_info` string like `"1h32min"`, `"45min"`, or
  `"resetou"`.
- If either percentual is already ≥95, don't start a task likely to get
  cut off mid-way. Parse `reset_info` into seconds (`resetou` → proceed
  now) and schedule the next attempt for then, chaining >3600s waits the
  same way as the reactive path below. This turns "react precisely after
  failing" into "avoid failing in the first place" — strictly better when
  it's available.

Most repos and most machines won't have this file. The loop must behave
correctly without it, which is exactly what the reactive path below is for.

- **Committed a task, or got blocked by a failed review, and pending tasks
  remain** (steps 6/7): run it again immediately — there's more work and
  capacity to do it.
- **Nothing pending, or no active feature** (steps 1/3): goal reached for
  now. Stop driving — don't keep re-invoking on a cadence just to confirm
  "still nothing."
- **Blocked by the branch or working-tree guard** (step 2): stop driving
  and surface it to the human. Retrying won't fix a dirty tree or a
  default-branch checkout — only a person can.
- **The call itself failed to run at all** (rate limit, quota, "overloaded",
  timeout — not an outcome reported by this command, but a failure to
  execute it): this is the one case worth a retry, never a "stop and wait
  for a human." If the failure message states an explicit reset time (e.g.
  "5-hour limit reached - resets 3:00 PM"), parse it and set
  `delaySeconds` to the time remaining until then — `ScheduleWakeup` caps a
  single call at 3600s, so a longer wait means chaining hops: wake at
  +3600s, recompute the remaining gap, reschedule again, until the reset
  time arrives. If no explicit reset time is given, fall back to a
  conservative fixed backoff (1500-1800s) and re-check on wake. Weekly caps
  can mean waiting up to 7 days — that's a lot of hops for a local session
  to sit through; if this repo's loop is likely to hit a weekly cap,
  `/schedule` survives that better than a session-bound `/loop`.

## Done When

- [ ] Zero or exactly one task was implemented this run — never more.
- [ ] No push, no PR, and no default-branch commit happened.
- [ ] `.specify/agentic-loop.log` has one new line describing the outcome.
- [ ] A notification was sent for any outcome that did real work or got
      blocked while work existed (steps 2/6/7); true no-ops where there was
      simply nothing to do (steps 1/3) stay silent in the log only.
