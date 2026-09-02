#!/usr/bin/env python3
"""Regenerate docs/ARDUPILOT_CHANGES.md from the live ArduPilot tree.

The ArduPilot clone is not part of this repository, so the only readable record
of what was changed there is patches/*.patch -- which is a diff, not something
you can follow while looking at the code. This turns the same diff into
annotated snippets: file path, real line numbers, and changed lines marked.

Line numbers go stale the moment upstream moves. Re-run this after any rebase
rather than trusting the file:

    ./scripts/make_changes_doc.py

Blocks are fenced as ```diff so GitHub and VSCode tint added lines green and
removed lines red. That costs C++ syntax colouring -- a deliberate trade, since
this document exists to show what changed, not to be read as source.
"""
import os
import re
import subprocess
import sys

AP = os.path.expanduser("~/ardupilot")
MAVLINK = os.path.join(AP, "modules/mavlink")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "docs/ARDUPILOT_CHANGES.md")
CONTEXT = 3

# Why each edit is where it is. Keyed by path as git reports it.
NOTES = {
    "modules/mavlink/message_definitions/v1.0/ardupilotmega.xml":
        "The protocol change itself, and the only file here that is not C++. "
        "Everything else in this document is downstream of these 16 lines: "
        "regenerating from them produces msgid **11070**, a **4-byte** payload "
        "and **CRC-extra 97**, and both the C build and pymavlink must agree on "
        "that 97 or the message is dropped with no error at either end.",

    "ArduCopter/GCS_MAVLink_Copter.h":
        "Declaration only. It sits with the three existing `handle_message_*` "
        "helpers rather than in `private:` with `handle_message()` itself, "
        "because that block is the group the message switch calls. No "
        "`override` -- this replaces nothing in the base class, and adding one "
        "would fail to compile.",

    "ArduCopter/GCS_MAVLink_Copter.cpp":
        "The handler, and the `case` that reaches it. Ids with no `case` fall "
        "through to the base class and vanish silently, which is why this step "
        "was built and tested before any motor behaviour existed.\n\n"
        "The range check is not redundant with the library's own guard. The "
        "library returns silently on a bad index -- correct for a library, "
        "useless to an operator. Without this check `motorfail 0` underflows to "
        "index 255 and `motorfail 7` sets a bit no frame reads; both look "
        "exactly like success.",

    "libraries/AP_Motors/AP_MotorsMulticopter.h":
        "The setter is **public** because `Copter.h` declares `motors` as "
        "`AP_MotorsMulticopter *`; put it one level down on `AP_MotorsMatrix` "
        "and the handler would need a cast. The mask is **protected** so "
        "`AP_MotorsMatrix` can read it directly, and carries an in-class `= 0` "
        "-- a `uint32_t` member is not zeroed for you, and an uninitialised "
        "mask would fail whichever motors its garbage bits happened to name, "
        "on a real aircraft as much as in SITL.",

    "libraries/AP_Motors/AP_MotorsMulticopter.cpp":
        "The setter. The bounds check is not politeness: `1U << motor_index` "
        "past the type's width is undefined behaviour in C++, and on ARM the "
        "hardware shift instruction uses only the low 5 bits, so a shift by 32 "
        "quietly becomes a shift by 0 and stops motor 1 instead of refusing.",

    "libraries/AP_Motors/AP_MotorsMatrix.cpp":
        "The kill. This is the last loop of `output_to_motors()`, downstream of "
        "the mixer, the stability patch, spool state, slew limiting and thrust "
        "linearisation -- so nothing left in the chain can rescale the zero "
        "away. Injecting any earlier fails: the stability patch's entire job is "
        "to renormalise outputs it cannot satisfy, so it would treat a zero as "
        "a demand to rebalance and the motor would keep turning.\n\n"
        "`_actuator[i]` is deliberately untouched. The controller goes on "
        "computing a demand for the dead motor and never learns it is being "
        "ignored -- which is precisely what a dead ESC looks like from inside "
        "the flight code.",
}

# Emission order: the wire format first, then inward to the motors.
ORDER = [
    "modules/mavlink/message_definitions/v1.0/ardupilotmega.xml",
    "ArduCopter/GCS_MAVLink_Copter.h",
    "ArduCopter/GCS_MAVLink_Copter.cpp",
    "libraries/AP_Motors/AP_MotorsMulticopter.h",
    "libraries/AP_Motors/AP_MotorsMulticopter.cpp",
    "libraries/AP_Motors/AP_MotorsMatrix.cpp",
]

HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args],
                          capture_output=True, text=True, check=True).stdout


def parse(diff_text, prefix=""):
    """{path: [ [(marker, new_lineno_or_None, text), ...], ...hunks... ]}"""
    files, path, hunk, lineno = {}, None, None, 0
    for raw in diff_text.split("\n"):
        # File headers first: "--- a/path" otherwise reads as a deleted line,
        # and "+++ b/path" as an added one.
        if raw.startswith("--- ") or raw.startswith("diff --git"):
            hunk = None
            continue
        if raw.startswith("+++ b/"):
            path = prefix + raw[6:]
            files[path] = []
            hunk = None
            continue
        if path is None:
            continue
        m = HUNK.match(raw)
        if m:
            lineno = int(m.group(1))
            hunk = []
            files[path].append(hunk)
            continue
        if hunk is None or not raw:
            continue
        head, body = raw[0], raw[1:]
        if head == "+":
            hunk.append(("+", lineno, body))
            lineno += 1
        elif head == "-":
            hunk.append(("-", None, body))          # gone; no new-file number
        elif head == " ":
            hunk.append((" ", lineno, body))
            lineno += 1
        # '\' (no newline at eof) and anything else is ignored
    return files


def render(hunk):
    width = max((len(str(n)) for _, n, _ in hunk if n), default=4)
    rows = []
    for marker, n, text in hunk:
        gutter = str(n).rjust(width) if n else "-" * width
        rows.append(f"{marker}{gutter} | {text}")
    return "```diff\n" + "\n".join(rows) + "\n```"


def main():
    ap_diff = git(AP, "diff", "--ignore-submodules", f"-U{CONTEXT}",
                  "--", "ArduCopter", "libraries")
    mav_diff = git(MAVLINK, "diff", f"-U{CONTEXT}")

    files = parse(ap_diff)
    files.update(parse(mav_diff, prefix="modules/mavlink/"))

    ap_base = git(AP, "rev-parse", "--short", "HEAD").strip()
    mav_base = git(MAVLINK, "rev-parse", "--short", "HEAD").strip()

    missing = [p for p in files if p not in NOTES]
    if missing:
        sys.exit(f"no note written for: {', '.join(missing)}\n"
                 f"Add one to NOTES in {__file__} before regenerating.")

    d = []
    d.append("# ArduPilot changes for `MOTOR_FAILURE_SET`")
    d.append("")
    d.append("Every edit made to the ArduPilot tree for this project, at the "
             "line numbers it currently occupies. Added lines are marked `+`, "
             "replaced lines `-`; unmarked lines are surrounding context.")
    d.append("")
    d.append("`~/ardupilot` is a separate clone and is **not** part of this "
             "repository, so these changes exist in git here only as "
             "[`patches/ardupilot.patch`](../patches/ardupilot.patch) and "
             "[`patches/mavlink.patch`](../patches/mavlink.patch). Re-apply "
             "them after a fresh clone or a wiped submodule with "
             "`./scripts/apply_patches.sh`.")
    d.append("")
    d.append("| | |")
    d.append("|---|---|")
    d.append(f"| ArduPilot base | `{ap_base}` |")
    d.append(f"| `modules/mavlink` base | `{mav_base}` |")
    d.append("| Generated by | `scripts/make_changes_doc.py` |")
    d.append("")
    d.append("**Line numbers go stale.** They are correct against the bases "
             "above. After a rebase, re-run `./scripts/make_changes_doc.py` "
             "rather than trusting this file.")
    d.append("")
    d.append("---")
    d.append("")

    for path in ORDER:
        if path not in files:
            continue
        d.append(f"## `{path}`")
        d.append("")
        d.append(NOTES[path])
        d.append("")
        for hunk in files[path]:
            numbered = [n for _, n, _ in hunk if n]
            d.append(f"**Lines {numbered[0]}–{numbered[-1]}**")
            d.append("")
            d.append(render(hunk))
            d.append("")
        d.append("---")
        d.append("")

    d.append("## Rebuilding after a change here")
    d.append("")
    d.append("```bash")
    d.append("# XML changed -> regenerate BOTH sides, or the message is dropped silently")
    d.append("docker exec sitl_drone bash -lc 'source ~/ardupilot/venv-ardupilot/bin/activate && \\")
    d.append("  cd ~/ardupilot && ./waf copter'")
    d.append("docker exec sitl_drone bash -lc 'source ~/ardupilot/venv-ardupilot/bin/activate && \\")
    d.append("  MAVLINK_DIALECT=ardupilotmega pip install --force-reinstall \\")
    d.append("    ~/ardupilot/modules/mavlink/pymavlink'")
    d.append("")
    d.append("# C++ only -> just the build")
    d.append("docker exec sitl_drone bash -lc 'source ~/ardupilot/venv-ardupilot/bin/activate && \\")
    d.append("  cd ~/ardupilot && ./waf copter'")
    d.append("")
    d.append("# then always, so the diff is not lost with the tree")
    d.append("./scripts/make_patches.sh")
    d.append("./scripts/make_changes_doc.py")
    d.append("```")
    d.append("")
    d.append("`PROJECT.md` §5 Technical ground truth has the full signal "
             "path; §7 Gotchas has the traps.")
    d.append("")

    with open(OUT, "w") as f:
        f.write("\n".join(d))
    print(f"wrote {os.path.relpath(OUT, REPO)} "
          f"({len(files)} files, ardupilot {ap_base}, mavlink {mav_base})")


if __name__ == "__main__":
    main()
