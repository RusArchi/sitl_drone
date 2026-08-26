# CLAUDE.md — rules for agents working in sitl_drone

## PROJECT.md is the ground truth

[PROJECT.md](PROJECT.md) holds the current state of this project: mission,
phase, environment, verified technical facts, decisions, gotchas, next actions.

**Read it first, before anything else, at the start of every session.** It is
cheaper than re-deriving the state from the code and the git log, and it records
things neither of those contain.

## Keep it current — same change, not later

Updating `PROJECT.md` is part of the work, not a follow-up task. A change is not
finished until the file reflects it.

**Update it whenever you:**

| Trigger | What to update |
|---|---|
| Complete or advance a phase | §1 Mission phase table, §2 Current status, §8 next actions |
| Verify something works (or find it broken) | §2 Current status — say what was verified and when |
| Make a design or tooling choice with an alternative | §6 decisions — one row, with the *why* |
| Hit a non-obvious failure and solve it | §7 gotchas — so nobody pays for it twice |
| **Get something wrong** — a false diagnosis, a broken change, a claim that did not hold | §10 troubleshooting log — see below. Not optional |
| Change the mixer, a line reference, or a param plan | §5 technical ground truth |
| Add, move, or delete a tracked file | §3 repo layout |
| Commit anything substantive | §9 changelog — one row, dated |

Also bump **Last updated** at the top, and the **Branch** line if it changed.

## Record your own mistakes — §10 Troubleshooting log, every time

When you get something wrong, write it into **§10 Troubleshooting log** as part
of the same change that fixes it. This is not a courtesy; a wrong diagnosis that
goes unrecorded is repeated by the next session, which has no memory of it.

**What counts.** A diagnosis that turned out to be false. A change that broke
something that was working. A claim stated with confidence that did not hold. A
tool or command that silently lied to you. A recommendation withdrawn after
measuring. Bugs in code you wrote *that the user hit*.

**What does not.** Ordinary iteration, a compile error you fixed a minute later,
or anything the user never saw and that taught you nothing.

**Format** — three lines, no more:

```
### YYYY-MM-DD — one-line title, in the user's terms

- **Believed:** what you thought was true, and why it was plausible.
- **Actually:** what was true, with the evidence that settled it.
- **Lesson:** the generalisation. Must be usable by someone who hits a
  *different* instance of the same trap.
```

Add **Cost:** when the mistake cost real time or destroyed a working state.

**Rules.**

- **§10 Troubleshooting log is append-only.** Everywhere else in this file, correct stale lines. Here,
  the history is the point — never edit or delete an old entry.
- **Write it plainly.** No hedging, no blaming the tool when the tool behaved as
  documented and you misread it.
- **Do it in the same change.** "I'll note it later" is how it gets lost.
- **Don't editorialise in the user's direction.** The entry is for the next
  engineer, not an apology.

If a mistake also leaves a reusable trap for anyone (not just a lesson about how
you worked), put the trap in §7 gotchas *as well* — §10 Troubleshooting log explains what went wrong,
§7 Gotchas tells the next person how to avoid it.

## How to write in it

- **State facts, not intentions.** "Verified working 2026-08-25" beats "should work".
  If something is untested, say so in those words.
- **Absolute dates.** Never "yesterday" or "recently" — the file outlives the session.
- **Record the why for decisions.** A decision without its reason gets re-litigated.
- **Correct, don't append.** When reality changes, edit the stale line. This file is
  a current-state document with a changelog at the end, not an append-only log.
- **Prune.** If a section stops being true or useful, delete it. Length is not value.
  Exception: §10 Troubleshooting log is append-only.
- **Keep it self-contained.** Someone with no session history should be able to pick
  up the work from this file alone.
- **Always name a section, never just number it.** Write "§7 Gotchas", not "§7" —
  in this file, in commit messages, and when talking to the user. A bare number
  asks the reader to hold a table of contents in their head. This applies to any
  numbered reference: phases, decision rows, steps.

## Precedence

Code > `PROJECT.md` > everything else. If the code contradicts `PROJECT.md`,
the code is right — **fix `PROJECT.md` in the same change**, don't just move on.

## Division of labour with the other docs

- `README.md` — short, public-facing: what this is, how to run it. Stable.
- `docs/ENVIRONMENT_SETUP.md` — the from-scratch provisioning reference. Changes
  only when the setup procedure itself changes.
- `PROJECT.md` — everything that moves.

Don't duplicate the setup guide into `PROJECT.md`; link to it.

## Working style on ArduPilot changes

Learning ArduCopter's structure is an explicit goal of this project (PROJECT.md
§1 Mission) — the end goal is a safety function that keeps the aircraft controllable on
three motors. So, for anything touching ArduPilot:

- **Explain before changing.** What the code does now, where the change goes,
  why there and not elsewhere.
- **Prefer hand-doable steps.** Name the file and function and make small,
  inspectable edits; don't bulk-patch what could be understood.
- **Understanding beats shortcuts** when they conflict.

This does not apply to the surrounding tooling (docker, scripts, docs) — move
fast there.

## Project-specific notes

- ArduPilot and `ardupilot_gazebo` are **separate clones** at `~/ardupilot` and
  `~/ardupilot_gazebo`, bind-mounted into the container. They are not part of this
  repo. Mixer patches land there; track the diff and the findings here.
- Anything running `sim_vehicle.py` or a pymavlink script must first
  `source ~/ardupilot/venv-ardupilot/bin/activate` (PEP 668 — see PROJECT.md §4 Environment).
- The container is **disposable**: `/home/rusik` is not bind-mounted, so anything
  written to `~/.bashrc` inside it is lost on recreate. Persistent env belongs in
  the Dockerfile as `ENV` (that is where the GZ vars now live).
- ArduPilot line references in `PROJECT.md` §5 Technical ground truth are pinned to master `cbe0c39`.
  Re-verify before relying on them, and update the pin when you do.
