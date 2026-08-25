# CLAUDE.md — rules for agents working in sitl_drone

## PROJECTS.md is the ground truth

[PROJECTS.md](PROJECTS.md) holds the current state of this project: mission,
phase, environment, verified technical facts, decisions, gotchas, next actions.

**Read it first, before anything else, at the start of every session.** It is
cheaper than re-deriving the state from the code and the git log, and it records
things neither of those contain.

## Keep it current — same change, not later

Updating `PROJECTS.md` is part of the work, not a follow-up task. A change is not
finished until the file reflects it.

**Update it whenever you:**

| Trigger | What to update |
|---|---|
| Complete or advance a phase | §1 phase table, §2 status, §8 next actions |
| Verify something works (or find it broken) | §2 status — say what was verified and when |
| Make a design or tooling choice with an alternative | §6 decisions — one row, with the *why* |
| Hit a non-obvious failure and solve it | §7 gotchas — so nobody pays for it twice |
| Change the mixer, a line reference, or a param plan | §5 technical ground truth |
| Add, move, or delete a tracked file | §3 repo layout |
| Commit anything substantive | §9 changelog — one row, dated |

Also bump **Last updated** at the top, and the **Branch** line if it changed.

## How to write in it

- **State facts, not intentions.** "Verified working 2026-08-25" beats "should work".
  If something is untested, say so in those words.
- **Absolute dates.** Never "yesterday" or "recently" — the file outlives the session.
- **Record the why for decisions.** A decision without its reason gets re-litigated.
- **Correct, don't append.** When reality changes, edit the stale line. This file is
  a current-state document with a changelog at the end, not an append-only log.
- **Prune.** If a section stops being true or useful, delete it. Length is not value.
- **Keep it self-contained.** Someone with no session history should be able to pick
  up the work from this file alone.

## Precedence

Code > `PROJECTS.md` > everything else. If the code contradicts `PROJECTS.md`,
the code is right — **fix `PROJECTS.md` in the same change**, don't just move on.

## Division of labour with the other docs

- `README.md` — short, public-facing: what this is, how to run it. Stable.
- `docs/ENVIRONMENT_SETUP.md` — the from-scratch provisioning reference. Changes
  only when the setup procedure itself changes.
- `PROJECTS.md` — everything that moves.

Don't duplicate the setup guide into `PROJECTS.md`; link to it.

## Project-specific notes

- ArduPilot and `ardupilot_gazebo` are **separate clones** at `~/ardupilot` and
  `~/ardupilot_gazebo`, bind-mounted into the container. They are not part of this
  repo. Mixer patches land there; track the diff and the findings here.
- Anything running `sim_vehicle.py` or a pymavlink script must first
  `source ~/ardupilot/venv-ardupilot/bin/activate` (PEP 668 — see PROJECTS.md §4).
- Env vars set in the container's `~/.bashrc` are invisible to non-interactive
  `docker exec`. Use `bash -lc '...'` or `docker/run.sh check`.
- ArduPilot line references in `PROJECTS.md` §5 are pinned to master `cbe0c39`.
  Re-verify before relying on them, and update the pin when you do.
