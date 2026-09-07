#!/usr/bin/env python3
"""Drive Conterm's agent hooks the way an agent CLI drives them.

Run this inside a Conterm pane. It reads the hook commands Conterm
installed for an agent, then runs them in order with the payloads that
agent really sends, spawned the way that agent really spawns them:
the command string handed to a shell, stdin/stdout/stderr on pipes
rather than the terminal, and its own process group. That last part is
what the hook script has to survive — with no controlling terminal of
its own it walks up the parent chain to find the pane's tty, and this
is the only way to exercise that walk without the agent installed.

    python3 scripts/hook-probe.py codex
    python3 scripts/hook-probe.py claude
    python3 scripts/hook-probe.py codex --to /tmp/out   # no pane needed
    python3 scripts/hook-probe.py codex --settings ./hooks.json

`--to` redirects the escape to a file and prints what was written, for
checking the payload wiring off a terminal.

The pill should follow the printed script: ready → thinking, a bubble
per tool call, "needs you" at the approval, then ready and gone.
"""

import argparse
import glob
import json
import os
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
SENTINEL = "# conterm"

# How each agent invokes a hook command. Codex hands the string to the
# user's login shell (codex-rs/hooks/src/engine/command_runner.rs);
# Claude Code uses a plain sh.
SPECS = {
    "claude": {
        "settings": f"{HOME}/.claude/settings.json",
        "shell": ["/bin/sh", "-c"],
    },
    "codex": {
        "settings": f"{HOME}/.codex/hooks.json",
        "shell": [os.environ.get("SHELL", "/bin/sh"), "-lc"],
    },
}

# libghostty passes on at most one desktop notification a second for the
# whole app, so events sent faster than that are dropped on the floor.
GAP = 1.2


def transcript_for(agent):
    """A real session file when the machine has one — the pane polls it —
    else a path that simply doesn't resolve."""
    if agent == "codex":
        found = glob.glob(f"{HOME}/.codex/sessions/*/*/*/rollout-*.jsonl")
    else:
        found = glob.glob(f"{HOME}/.claude/projects/*/*.jsonl")
    return max(found, key=os.path.getmtime) if found else f"/tmp/{agent}-probe.jsonl"


def rich_session(transcript):
    """A longer Codex turn, for watching the chrome rather than checking it:
    two calls open at once, one comes back failed, an approval interrupts,
    and a second prompt follows."""
    common = {"session_id": "probe", "cwd": os.getcwd(), "transcript_path": transcript}
    def pre(cid, name, cmd):
        return ("PreToolUse", dict(common, turn_id="t1", tool_name=name,
                                   tool_use_id=cid, tool_input={"command": cmd},
                                   hook_event_name="PreToolUse"))
    def post(cid, name, cmd):
        return ("PostToolUse", dict(common, turn_id="t1", tool_name=name,
                                    tool_use_id=cid, tool_input={"command": cmd},
                                    tool_response={"output": "ok"},
                                    hook_event_name="PostToolUse"))
    steps = [
        (("SessionStart", dict(common, hook_event_name="SessionStart",
                               model="gpt-5-codex", source="startup")),
         "pill appears, Codex is Ready"),
        (("UserPromptSubmit", dict(common, turn_id="t1", prompt="ship the cluster",
                                   hook_event_name="UserPromptSubmit")),
         "pill turns neon, thinking"),
        (pre("call_1", "Bash", "terraform plan -out tf.plan"), "Terraform bubble opens"),
        (pre("call_2", "Bash", "kubectl get pods -A"), "Kubernetes bubble joins it"),
        (post("call_1", "Bash", "terraform plan -out tf.plan"), "Terraform settles"),
        (pre("call_3", "apply_patch", "*** Begin Patch\n*** Update File: infra/main.tf"),
         "Edit bubble opens"),
        (post("call_2", "Bash", "kubectl get pods -A"), "Kubernetes settles"),
        (("PermissionRequest", dict(common, turn_id="t1", tool_name="Bash",
                                    tool_input={"command": "terraform apply tf.plan"},
                                    hook_event_name="PermissionRequest")),
         "pill reads Codex needs you"),
        (post("call_3", "apply_patch", "*** Begin Patch"), "Edit settles"),
        (pre("call_4", "Bash", "terraform apply tf.plan"), "approved — Terraform again"),
        (post("call_4", "Bash", "terraform apply tf.plan"), "Terraform settles"),
        (("Stop", dict(common, turn_id="t1", stop_hook_active=False,
                       last_assistant_message="applied", hook_event_name="Stop")),
         "back to Ready"),
        (("UserPromptSubmit", dict(common, turn_id="t2", prompt="now the images",
                                   hook_event_name="UserPromptSubmit")),
         "thinking again, a second turn"),
        (pre("call_5", "Bash", "docker compose up -d"), "Docker bubble"),
        (pre("call_6", "Bash", "gh pr create --fill"), "GitHub bubble joins it"),
        (post("call_5", "Bash", "docker compose up -d"), "Docker settles"),
        (("Stop", dict(common, turn_id="t2", stop_hook_active=False,
                       last_assistant_message="done", hook_event_name="Stop")),
         "Ready — the open GitHub call settles with the turn"),
        (("SessionEnd", dict(common, reason="other", hook_event_name="SessionEnd")),
         "pill disappears"),
    ]
    return [(e, p, note) for (e, p), note in steps]


def session(agent, transcript, rich=False):
    """The events one turn raises, in order, with each agent's own payload
    shape. Field order matters: the hook script reads the outer
    tool_use_id by the side of tool_input it falls on."""
    if rich and agent == "codex":
        return rich_session(transcript)
    common = {"session_id": "probe", "cwd": os.getcwd(), "transcript_path": transcript}
    if agent == "codex":
        return [
            ("SessionStart", dict(common, hook_event_name="SessionStart",
                                  model="gpt-5-codex", source="startup"),
             "pill appears, Codex is Ready"),
            ("UserPromptSubmit", dict(common, turn_id="t1", prompt="probe",
                                      hook_event_name="UserPromptSubmit"),
             "pill turns neon, thinking"),
            ("PreToolUse", dict(common, turn_id="t1", tool_name="Bash",
                                matcher_aliases=["shell"], tool_use_id="call_1",
                                tool_input={"command": "terraform plan"},
                                hook_event_name="PreToolUse"),
             "terraform bubble opens"),
            ("PostToolUse", dict(common, turn_id="t1", tool_name="Bash",
                                 tool_use_id="call_1",
                                 tool_input={"command": "terraform plan"},
                                 tool_response={"output": "ok"},
                                 hook_event_name="PostToolUse"),
             "terraform bubble retires to History"),
            ("PreToolUse", dict(common, turn_id="t1", tool_name="apply_patch",
                                tool_use_id="call_2",
                                tool_input={"command": "*** Begin Patch\n"
                                                       "*** Update File: src/App.swift"},
                                hook_event_name="PreToolUse"),
             "edit bubble opens"),
            ("PermissionRequest", dict(common, turn_id="t1", tool_name="Bash",
                                       tool_input={"command": "rm -rf build"},
                                       hook_event_name="PermissionRequest"),
             "pill reads Codex needs you"),
            ("Stop", dict(common, turn_id="t1", stop_hook_active=False,
                          last_assistant_message="done", hook_event_name="Stop"),
             "back to Ready, open bubbles settle"),
            ("SessionEnd", dict(common, reason="other", hook_event_name="SessionEnd"),
             "pill disappears"),
        ]
    return [
        ("SessionStart", dict(common, hook_event_name="SessionStart", source="startup"),
         "pill appears, Claude is Ready"),
        ("UserPromptSubmit", dict(common, hook_event_name="UserPromptSubmit", prompt="probe"),
         "pill turns neon, thinking"),
        ("PreToolUse", dict(common, hook_event_name="PreToolUse", tool_name="Bash",
                            tool_input={"command": "kubectl get pods -A"},
                            tool_use_id="toolu_1"),
         "kubernetes bubble opens"),
        ("PostToolUse", dict(common, hook_event_name="PostToolUse", tool_name="Bash",
                             tool_input={"command": "kubectl get pods -A"},
                             tool_response={"stdout": "ok"}, tool_use_id="toolu_1"),
         "kubernetes bubble retires to History"),
        ("PostToolUseFailure", dict(common, hook_event_name="PostToolUseFailure",
                                    tool_name="Edit",
                                    tool_input={"file_path": "src/App.swift"},
                                    tool_use_id="toolu_2"),
         "no bubble — nothing opened this id"),
        ("Notification", dict(common, hook_event_name="Notification"),
         "pill reads Claude needs you"),
        ("Stop", dict(common, hook_event_name="Stop"),
         "back to Ready, open bubbles settle"),
        ("SessionEnd", dict(common, hook_event_name="SessionEnd"),
         "pill disappears"),
    ]


def installed_commands(settings_path):
    """Conterm's hook command per event, by its sentinel."""
    try:
        with open(settings_path) as f:
            hooks = json.load(f).get("hooks", {})
    except (OSError, ValueError):
        return {}
    out = {}
    for event, groups in hooks.items():
        for group in groups if isinstance(groups, list) else []:
            for entry in group.get("hooks", []):
                if SENTINEL in entry.get("command", ""):
                    out[event] = entry["command"]
    return out


def fire(shell, command, payload, tty):
    """Spawn one hook the way the agent does: the command string given to
    a shell, every stream a pipe, and setpgid into a fresh process group
    (not setsid — the agent keeps its session, and so the tty stays
    reachable up the parent chain)."""
    env = dict(os.environ)
    if tty:
        env["CONTERM_HOOK_TTY"] = tty
    proc = subprocess.Popen(
        shell + [command],
        env=env, cwd=HOME, preexec_fn=os.setpgrp,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    _, err = proc.communicate(json.dumps(payload).encode(), timeout=10)
    return proc.returncode, err.decode(errors="replace").strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("agent", choices=sorted(SPECS))
    ap.add_argument("--to", metavar="FILE",
                    help="write the escape here instead of the pane's tty")
    ap.add_argument("--settings", metavar="FILE",
                    help="read hook commands from here, not the installed file")
    ap.add_argument("--rich", action="store_true",
                    help="a longer turn: overlapping calls, a failure, two prompts")
    args = ap.parse_args()

    spec = SPECS[args.agent]
    settings = args.settings or spec["settings"]
    commands = installed_commands(settings)
    if not commands:
        sys.exit(f"no Conterm hooks in {settings} — "
                 f"turn the integration on in Settings → Config first")

    if args.to:
        open(args.to, "w").close()
    else:
        print(f"pane: {os.ttyname(0) if os.isatty(0) else 'stdin is not a tty'}")
    transcript = transcript_for(args.agent)
    print(f"agent: {args.agent}   shell: {' '.join(spec['shell'])}")
    print(f"hooks: {settings}")
    print(f"transcript: {transcript}")
    print(f"events installed: {', '.join(sorted(commands))}\n")

    sent = 0
    for event, payload, expected in session(args.agent, transcript, args.rich):
        command = commands.get(event)
        if not command:
            print(f"  · {event:<18} not installed, skipped")
            continue
        code, err = fire(spec["shell"], command, payload, args.to)
        note = f"exit {code}" if code else "ok"
        if err:
            note += f" — stderr: {err}"
        print(f"  → {event:<18} {note:<28} {expected}")
        sent += 1
        time.sleep(GAP)

    if args.to:
        with open(args.to, "rb") as f:
            raw = f.read()
        emitted = [c.split("conterm-agent:", 1)[1]
                   for c in raw.decode(errors="replace").split("\a")
                   if "conterm-agent:" in c]
        print(f"\n{len(emitted)} of {sent} reached {args.to}:")
        for line in emitted:
            print(f"  {line}")
        if len(emitted) != sent:
            sys.exit("some events wrote nothing")
    else:
        print(f"\n{sent} events sent. A hook that found no tty writes nothing and "
              f"still exits 0 — if the pill never moved, that is the failure.")


if __name__ == "__main__":
    main()
