---
description: "Turns a raw feature/bug prompt into a spec-kit feature (specify → clarify → plan → tasks), then hands off to /loop /agentic-loop to implement it unattended. One-shot bootstrap — see 'Driving this with /loop' for how a driver should treat its outcome, including mid-bootstrap rate-limit retries."
---

## User Input

```text
$ARGUMENTS
```

This is the raw request — a bug report, a feature ask, whatever a human
would otherwise type after `/speckit-specify`. If empty, stop and report
usage; there's nothing to bootstrap from.

# Agentic Loop Intake — Bootstrap a Prompt Into Work, Then Hand Off

This is the missing front half of `/agentic-loop`: that command only grinds
through an *existing* `tasks.md`. This command creates one, from a plain
description, then starts the grind automatically. Usage:
`/agentic-loop-intake "<descrição do bug ou feature>"` — one prompt in,
spec-kit ceremony and implementation happen unattended from there.

## Guardrails

- **Working tree must be clean before this starts** — same reasoning as
  `/agentic-loop`'s guard: don't create a new feature branch on top of a
  human's uncommitted work. If `git status --porcelain` reports anything,
  stop and notify instead of proceeding.
- **Never double-create a feature.** Before running `/speckit-specify`,
  check whether `.specify/feature.json` already points at a feature dir
  with a `spec.md`, on a branch that isn't the repo's default — if so,
  this is a retry of a bootstrap that got partway through (e.g. a rate
  limit hit during `/speckit-plan`), not a fresh request. Skip straight to
  whichever of `/speckit-clarify` / `/speckit-plan` / `/speckit-tasks`
  hasn't produced its output file yet, instead of re-running
  `/speckit-specify` and creating a second, duplicate feature.
- **A command left mid-question is not a failure.** `/speckit-specify` and
  `/speckit-clarify` can each legitimately stop and ask the human something
  (bounded to 3 and 5 questions respectively, and only for genuinely
  high-impact ambiguity — most well-scoped bug reports won't trigger this
  at all). If that happens, stop the whole pipeline here, log it, and
  notify with the exact question(s) — do not guess an answer on the
  human's behalf just to keep the pipeline moving unattended.

## Outline

1. Check the working-tree guard above. If dirty, log
   `"<timestamp> working tree dirty, refusing to bootstrap"` to
   `.specify/agentic-loop.log`, notify, and stop.

2. Check the double-create guard above. If this looks like a resume, note
   which of `spec.md`/`plan.md`/`tasks.md` already exist and jump to the
   matching step below instead of starting from step 3.

3. Run `/speckit-specify` with `$ARGUMENTS` as its input.
   - If it completes with a written `spec.md` and no open question: continue.
   - If it's presenting `[NEEDS CLARIFICATION]` questions and waiting: stop
     here. Log `"<timestamp> specify waiting on clarification"`, notify with
     the question(s) verbatim, and end this run — do not proceed to
     clarify/plan/tasks with an unanswered question outstanding.

4. Run `/speckit-clarify` (no arguments needed — it operates on the spec
   `/speckit-specify` just wrote).
   - If it reports no critical ambiguities: continue immediately, no human
     input needed.
   - If it's mid-question and waiting: stop, log, notify with the
     question(s), same handling as step 3.

5. Run `/speckit-plan`.
   - Its own gate errors on unresolved clarifications — treat that error
     the same as a stop-and-surface case (steps 3/4), not a retryable
     failure: something upstream should have caught this but didn't, so
     surface it rather than guessing past it.

6. Run `/speckit-tasks`.

7. **Hand off.** If `tasks.md` now exists with at least one task: invoke
   the `loop` skill with `/agentic-loop` as its argument (dynamic mode) —
   this starts the actual unattended grind, with all of `/agentic-loop`'s
   existing hard boundaries (no push/PR, bounded retries, independent
   review, rate-limit backoff) applying from here on, unchanged.

8. **Log and notify.** Append one line to `.specify/agentic-loop.log`:
   timestamp, feature dir, outcome (`handed off to agentic-loop` /
   `waiting on clarification: <question>` / `blocked: <why>`). Notify in
   every case — unlike `/agentic-loop`'s per-task no-ops, a bootstrap run
   always did something worth knowing about.

## Driving this with /loop

Wrap this in `/loop /agentic-loop-intake "<prompt>"` if you want the
bootstrap phase itself to survive a rate limit, not just the grind phase
after handoff (which already gets that for free once step 7 runs). Apply
the same contract as `/agentic-loop`'s own "Driving this with /loop"
section:

- **Ended waiting on a clarification question** (steps 3/4): stop driving,
  surface it to the human. This isn't retryable — only a person can answer
  it, and blindly re-running would either ask again or, worse, risk
  skipping past it.
- **Handed off successfully** (step 7): stop driving *this* command — the
  `/agentic-loop` loop it just started is now the active one and manages
  its own continuation. Driving both at once would double-run the grind.
- **The call itself failed to run at all** (rate limit, quota, "overloaded",
  timeout): the one retryable case. Same reset-time parsing and chained
  ≤3600s backoff as `/agentic-loop`'s contract, including the optional
  proactive check against a local `claude-usage`-style `usage_data.json`
  if present on this machine.

## Done When

- [ ] Either: stopped cleanly on a human-input question, with the question
      logged and notified — or: `tasks.md` exists and `/agentic-loop` has
      been started on it.
- [ ] No feature was double-created on a retry.
- [ ] No push, no PR — this command only ever hands off into
      `/agentic-loop`'s boundaries, never bypasses them.
