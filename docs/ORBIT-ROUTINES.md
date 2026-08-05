# Orbit — Routines

**Built.** `State/Routines.swift` holds the model and the store; the panel,
launcher and run reconciliation live in `OrbitOverlay`. This document is the
design it was built to, and the record of what is deliberately not done yet.

## Not done yet

- **Idempotence guidance.** Nothing pushes a state-changing step toward the
  `ansible` kind; the editor takes whatever kind you pick.
- **Danger gating.** A routine that targets a context `KubeContextWatch.isDanger`
  flags runs like any other. Same gap as the rest of Orbit — see `ORBIT.md` §4.
- **Per-host output in the history.** A run records a step's outcome, not each
  target's captured output; the scheduler holds that until the action ages out.
- **`.choice` inputs have no options editor** — the field exists on the model and
  the launcher renders a picker, but the editor can't populate the list yet.

---

## The goal

A **routine** is a named, parameterised, repeatable piece of operations work you
own: *add this ssh key to these servers*, *deploy this project*, *put the site
into maintenance mode*. You write it once, then run it — now, on a schedule, or
after something else finishes — and afterwards you can see exactly what ran
where and what it said.

This is the answer to Orbit's biggest gap: nothing accrues. You enter, do a
thing, leave, and the map has no memory of it. A routine you scheduled is a
reason to come back.

A routine is the **only** saved sequence of steps in the app. Boards used to
carry their own (`OrbitFlow`); `RoutineStore.adoptSavedFlows` lifts them into the
library once, and `OrbitSpace.flows` now only decodes.

## What already exists (do not rebuild it)

- `OrbitEngine` (`State/OrbitEngine.swift`, `.shared`) owns the clock and **all**
  execution: dependency and trigger gating, ssh / scp / local `Process` fan-out
  concurrently across targets, timeouts, real cancel, the headless Ansible
  surface, cross-session agent steer. It runs **app-wide**, kicked at launch and
  after any mutation, so work fires whether or not Orbit is on screen. The clock
  is demand-driven — no timer when nothing is planned.
- `OrbitScheduler` holds the plan and its state transitions.
- `OrbitFlow` / `FlowStep` (`State/OrbitModel.swift`) is already a named sequence
  of steps with a kind (`run` / `ansible` / `copy`), a payload, targets, become /
  check flags, and per-step `continueOnFailure`.

A routine is not a new engine. It is `OrbitFlow` grown four things it lacks.

## What it is missing

**1. Parameters.** `OrbitFlow` bakes its targets and payload in, so "deploy this
project" can only ever deploy the project it was saved with. A routine needs
inputs bound at run time:

```swift
struct RoutineInput: Codable, Identifiable {
    enum Kind: String, Codable { case text, hosts, path, choice, secret }
    var id = UUID()
    var key: String          // referenced in a payload as {{key}}
    var label: String
    var kind: Kind
    var choices: [String]    // .choice only
    var defaultValue: String
}
```

Substitution happens once, at launch, into a resolved copy of the steps — never
at execution time, so what ran is exactly what was recorded. `secret` is never
persisted and never written to the run log.

**2. A library, not a board.** `OrbitFlow` is saved *inside* `OrbitSpace`, so a
routine belongs to one board. Routines are yours: a top-level
`RoutineStore` (its own file under Application Support, like `FrecencyStore`),
listed in one place, runnable from any space. Spaces may *reference* a routine;
they must not own it.

**3. Provenance.** Every launch writes a `RoutineRun`: which routine, at which
version, the inputs it was given (secrets redacted), start and end, and per
step per host the exit status and captured output. One screen answers "did the
key land on all twelve?" — the thing you actually came back for. The timeline
deck already draws live actions; this is the durable record underneath it, and
the deck should read from it rather than keeping its own.

**4. Idempotence, honestly.** "Add this ssh key" must be safe to run twice.
Ansible is already wired in and is the right tool for state-changing work; raw
shell is right for one-shots. A routine step should say which it is, and the
editor should push state-changing work toward the `ansible` kind rather than
letting everything be a `run` that happens to work the first time.

## Shape of the work

1. **Model** — `Routine` (name, inputs, steps, notes), `RoutineRun`,
   `RoutineStore` with disk persistence. Migrate existing per-space `flows` into
   the library once, keyed by space name, and leave `OrbitSpace.flows` decoding
   for old boards.
2. **Launch** — resolve inputs into steps, hand the resolved steps to
   `OrbitScheduler` as a chained plan, record the `RoutineRun` as it goes. The
   engine needs no changes; this is a translation layer.
3. **Editor** — a routine is a list of steps and a list of inputs. Reuse the
   composer's step editor (`stepEditor` in `OrbitOverlay`); add the input list
   and a `{{key}}` picker.
4. **Runner** — pick a routine, fill its inputs, choose *now* / *at a time* /
   *after X*, run. The host input should be able to take the map's current
   selection, so "these three" is a click.
5. **History** — the run list, and one run's detail. This is where the feature
   earns its keep; build it properly, not as a log dump.

## Constraints

- Destructive verbs need the same gate as the rest of Orbit: a routine that
  targets a context `KubeContextWatch.isDanger` flags, or that carries an
  `ansible` step without `--check` available, should say so before it runs. See
  the safety note in `ORBIT.md` §4 — this is the same gap.
- Nothing here may poll. The engine's clock is demand-driven and must stay that
  way; a library of routines that aren't scheduled costs nothing.
- Secrets never reach `UserDefaults`, the run log, or the timeline caption.
