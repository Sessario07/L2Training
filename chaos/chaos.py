#!/usr/bin/env python3
"""
Chaos driver for RCA practice.

    ./chaos.py list                 what scenarios exist (no spoilers)
    ./chaos.py break                inject a RANDOM scenario
    ./chaos.py break <id>           inject a specific one
    ./chaos.py status               is something currently broken?
    ./chaos.py hint                 one nudge, no answer
    ./chaos.py reveal               the full root cause
    ./chaos.py fix                  restore, and time how long you took

The point is `break` without an argument. If you pick the scenario you already
know what is wrong, and you are rehearsing rather than diagnosing.
"""
import json
import os
import random
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATE = HERE / ".active"          # gitignored: holds the answer while broken
LOG = HERE / "history.log"        # a record of what you practised

RED, GRN, YLW, BLU, DIM, OFF = (
    "\033[31m", "\033[32m", "\033[33m", "\033[36m", "\033[2m", "\033[0m"
)


def load_scenarios():
    """Minimal YAML reader for this file's specific shape.

    Deliberately avoids a PyYAML dependency so the toolkit runs anywhere.
    """
    text = (HERE / "scenarios.yaml").read_text()
    blocks = re.split(r"\n  - id: ", text)[1:]
    out = []
    for b in blocks:
        s = {"id": b.split("\n")[0].strip()}
        for field in ("name", "difficulty", "layer", "symptom", "hint", "root_cause"):
            m = re.search(rf"^    {field}: (.+?)(?=\n    \w+:|\n  - id:|\Z)",
                          b, re.S | re.M)
            if m:
                v = m.group(1).strip()
                if v.startswith(">-") or v.startswith("|"):
                    v = " ".join(l.strip() for l in v.split("\n")[1:] if l.strip())
                s[field] = v.strip('"')
        for field in ("inject", "restore"):
            m = re.search(rf"^    {field}: \|\n(.*?)(?=\n    \w+:|\n  - id:|\Z)",
                          b, re.S | re.M)
            if m:
                s[field] = "\n".join(l[6:] for l in m.group(1).split("\n")).strip()
            else:
                m2 = re.search(rf'^    {field}: "(.+)"', b, re.M)
                if m2:
                    s[field] = m2.group(1)
        out.append(s)
    return out


def sh(cmd, check=True):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and r.returncode != 0:
        print(f"{RED}command failed:{OFF} {cmd}\n{r.stderr.strip()}")
    return r


# The ONLY cluster this tool may ever touch. The AWS account is shared with
# ~30 other learners, several of whom run their own EKS clusters. A stale
# kubeconfig context pointing at someone else's cluster would mean injecting
# faults into THEIR environment.
EXPECTED_CLUSTER = "l2lab-sawibowo"


def kubectl_ok():
    """Refuse to do anything unless kubectl is pointed at OUR cluster."""
    ctx = sh("kubectl config current-context", check=False)
    if ctx.returncode != 0:
        print(f"{RED}No kubectl context.{OFF} Run: make kubeconfig")
        sys.exit(1)

    current = ctx.stdout.strip()
    if EXPECTED_CLUSTER not in current:
        print(f"{RED}REFUSING TO RUN.{OFF}")
        print(f"  kubectl context is : {current}")
        print(f"  expected it to contain: {EXPECTED_CLUSTER}")
        print()
        print("  This account is shared with other learners. Injecting a fault")
        print("  into the wrong cluster would break someone else's work.")
        print(f"  Fix with: make kubeconfig")
        sys.exit(1)

    r = sh("kubectl get ns l2lab", check=False)
    if r.returncode != 0:
        print(f"{RED}Cannot reach the l2lab namespace.{OFF} Run: make kubeconfig")
        sys.exit(1)


def cmd_list(scenarios):
    print(f"\n  {'ID':<20} {'DIFF':<6} {'LAYER':<12} SYMPTOM")
    print("  " + "-" * 90)
    for s in sorted(scenarios, key=lambda x: (x.get("difficulty", "9"), x["id"])):
        d = int(s.get("difficulty", 1))
        stars = ("*" * d).ljust(5)
        sym = s.get("symptom", "")[:52]
        print(f"  {s['id']:<20} {stars:<6} {s.get('layer',''):<12} {DIM}{sym}{OFF}")
    print(f"\n  {len(scenarios)} scenarios. Run {BLU}./chaos.py break{OFF} "
          f"to inject a random one.\n")


def cmd_break(scenarios, want=None):
    kubectl_ok()
    if STATE.exists():
        active = json.loads(STATE.read_text())
        print(f"{YLW}Something is already broken{OFF} "
              f"(injected {active['at']}).")
        print(f"Run {BLU}./chaos.py fix{OFF} before injecting another.")
        sys.exit(1)

    if want:
        matches = [s for s in scenarios if s["id"] == want]
        if not matches:
            print(f"{RED}No scenario '{want}'.{OFF} Try ./chaos.py list")
            sys.exit(1)
        s = matches[0]
    else:
        s = random.choice(scenarios)

    # Snapshot anything the restore step needs to put back.
    snapshot = {}
    if s.get("restore") == "RESTORE_FROM_SNAPSHOT":
        r = sh("kubectl -n l2lab get deploy frontend -o "
               "jsonpath='{.spec.template.spec.containers[0].image}'")
        snapshot["frontend_image"] = r.stdout.strip().strip("'")

    print(f"\n  injecting... {DIM}(not telling you which){OFF}")
    r = subprocess.run(s["inject"], shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"{RED}injection failed:{OFF}\n{r.stderr}")
        sys.exit(1)

    STATE.write_text(json.dumps({
        "id": s["id"],
        "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "started": time.time(),
        "snapshot": snapshot,
    }, indent=2))

    print(f"\n  {RED}Something is now broken.{OFF}\n")
    print(f"  {BLU}Reported symptom:{OFF}")
    print(f"    \"{s.get('symptom','users report a problem')}\"\n")
    print(f"  Difficulty: {'*' * int(s.get('difficulty', 1))}\n")
    print(f"  Start here:")
    print(f"    make status          {DIM}what is unhealthy right now{OFF}")
    print(f"    make events          {DIM}what changed{OFF}")
    print(f"    make grafana         {DIM}dashboards{OFF}")
    print(f"    make diagnose        {DIM}capture evidence before it rotates{OFF}\n")
    print(f"  Stuck? {BLU}./chaos.py hint{OFF}   "
          f"Give up? {BLU}./chaos.py reveal{OFF}   "
          f"Done? {BLU}./chaos.py fix{OFF}\n")


def _active(scenarios):
    if not STATE.exists():
        print(f"{GRN}Nothing is broken.{OFF} Run ./chaos.py break")
        sys.exit(0)
    st = json.loads(STATE.read_text())
    s = next(x for x in scenarios if x["id"] == st["id"])
    return st, s


def cmd_status(scenarios):
    if not STATE.exists():
        print(f"\n  {GRN}Nothing injected.{OFF} The environment should be healthy.\n")
        return
    st, _ = _active(scenarios)
    mins = (time.time() - st["started"]) / 60
    print(f"\n  {RED}A fault is active.{OFF}  injected {st['at']}  "
          f"({mins:.0f} min ago)\n")


def cmd_hint(scenarios):
    st, s = _active(scenarios)
    print(f"\n  {YLW}Hint:{OFF} {s.get('hint','No hint recorded.')}\n")


def cmd_reveal(scenarios):
    st, s = _active(scenarios)
    mins = (time.time() - st["started"]) / 60
    print(f"\n  {BLU}Scenario:{OFF} {s['id']} — {s.get('name','')}")
    print(f"  {BLU}Layer:{OFF} {s.get('layer','')}   "
          f"{BLU}Time so far:{OFF} {mins:.0f} min\n")
    print(f"  {BLU}Root cause:{OFF}")
    for line in _wrap(s.get("root_cause", ""), 74):
        print(f"    {line}")
    print(f"\n  {BLU}What was injected:{OFF}")
    for line in s["inject"].strip().split("\n"):
        print(f"    {DIM}{line}{OFF}")
    print(f"\n  Write it up: docs/rca/TEMPLATE.md, then ./chaos.py fix\n")


def cmd_fix(scenarios):
    kubectl_ok()
    st, s = _active(scenarios)
    restore = s.get("restore", "")
    if restore == "RESTORE_FROM_SNAPSHOT":
        img = st["snapshot"].get("frontend_image")
        restore = (f"kubectl -n l2lab set image deployment/frontend nginx={img}")

    print(f"\n  restoring {s['id']}...")
    r = subprocess.run(restore, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"{RED}restore failed:{OFF}\n{r.stderr}")
        print(f"{YLW}Fix by hand, then delete {STATE}{OFF}")
        sys.exit(1)

    mins = (time.time() - st["started"]) / 60
    with LOG.open("a") as f:
        f.write(f"{st['at']}\t{s['id']}\t{mins:.1f}min\n")
    STATE.unlink()

    print(f"  {GRN}restored.{OFF}  time to resolution: {mins:.0f} min")
    print(f"  logged to chaos/history.log\n")
    print(f"  Give it a minute, then confirm: {BLU}make verify{OFF}\n")


def _wrap(text, width):
    words, line, out = text.split(), "", []
    for w in words:
        if len(line) + len(w) + 1 > width:
            out.append(line)
            line = w
        else:
            line = f"{line} {w}".strip()
    if line:
        out.append(line)
    return out


def main():
    scenarios = load_scenarios()
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    arg = sys.argv[2] if len(sys.argv) > 2 else None
    {
        "list": lambda: cmd_list(scenarios),
        "break": lambda: cmd_break(scenarios, arg),
        "status": lambda: cmd_status(scenarios),
        "hint": lambda: cmd_hint(scenarios),
        "reveal": lambda: cmd_reveal(scenarios),
        "fix": lambda: cmd_fix(scenarios),
    }.get(cmd, lambda: print(__doc__))()


if __name__ == "__main__":
    main()
