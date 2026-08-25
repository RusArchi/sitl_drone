# AGENTS.md

The instructions for agents working in this repo live in **[CLAUDE.md](CLAUDE.md)**.
Read that file — it applies to every agent, not just Claude Code. This file exists
only so agents that look for `AGENTS.md` by convention find their way there.

The short version, in case you read nothing else:

1. **[PROJECT.md](PROJECT.md) is the project's ground truth.** Read it first,
   before the code or the git log. It records the current phase, what is verified
   working, the ArduPilot mixer map, decisions with their reasons, and the setup
   gotchas already paid for.
2. **Keep it current in the same change, not later.** A change is not finished
   until `PROJECT.md` reflects it. CLAUDE.md has the trigger table for what to
   update when.
3. **Precedence: code > `PROJECT.md` > everything else.** If the code contradicts
   `PROJECT.md`, the code is right — fix `PROJECT.md` in the same change.

Everything else — how to write in it, the division of labour with `README.md` and
`docs/ENVIRONMENT_SETUP.md`, and the project-specific traps (the PEP 668 venv, the
non-interactive `docker exec` env-var gap) — is in [CLAUDE.md](CLAUDE.md).
