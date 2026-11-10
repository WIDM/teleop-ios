#!/usr/bin/env python3
"""Report on teleop holds from the server's own logs, with suggested Settings values.

The server (Leo's S4 simulator) writes two files:
  - the run log, with one "S4 POSE STOP" line per finished hold and one "[S4 POSE REJECT]" per refused one
  - the network log (JSON lines), with every message in and out, including each pose_update

Usage:
  scripts/analyze_holds.py --host luchienlin@140.115.54.62            # fetch both over SSH
  scripts/analyze_holds.py --run-log s4_run.log --net-log s4.jsonl    # local copies
  add --since 16:30 to look only at holds after that time today

The suggestions are rules of thumb over these numbers, not a fitted model. Read the table before trusting them.
"""

import argparse
import ast
import json
import math
import re
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field

# Every run log: the start script empties s4_run.log on each launch, and other launch modes write their own.
REMOTE_RUN_LOG = "~/thomas_isaac/logs/s4_*.log"
REMOTE_NET_LOG = "~/thomas_isaac/robotics/data/network_logs/s4_pick_place.jsonl"
# The server E-stops when the commanded position leads the arm by more than this.
SERVER_LEAD_TRIP_M = 0.10


@dataclass
class Hold:
    seq: int
    start_ms: int = 0
    end_ms: int = 0
    commanded_m: list = field(default_factory=lambda: [0.0, 0.0, 0.0])
    arm_m: list = field(default_factory=lambda: [0.0, 0.0, 0.0])
    wall_s: float = 0.0
    sim_steps: int = 0
    clamped: bool = False
    ended_by: str = "release"
    path_m: float = 0.0
    peak_speed_m_s: float = 0.0
    samples: int = 0

    @property
    def commanded(self):
        return math.dist(self.commanded_m, [0, 0, 0])

    @property
    def arm(self):
        return math.dist(self.arm_m, [0, 0, 0])

    @property
    def tracking(self):
        """Share of the commanded distance the arm covered. None when the command was too small to judge."""
        return self.arm / self.commanded if self.commanded >= 0.02 else None

    @property
    def wander(self):
        """Path length over net distance of the command. 1.0 is a straight line; higher means shake or detours."""
        return self.path_m / self.commanded if self.commanded >= 0.02 else None


def parse_net_log(lines):
    """Holds from the message stream: pose_start opens one, the matching final ack or a disconnect closes it."""
    holds, open_hold, last = {}, None, None
    for line in lines:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        message = record.get("message") or {}
        kind, payload = message.get("type"), message.get("payload") or {}
        at = record.get("server_ts", 0)
        direction = record.get("direction")
        if direction == "in" and kind == "pose_start":
            open_hold = Hold(seq=message.get("seq", 0), start_ms=at)
            holds[(open_hold.seq, at)] = open_hold
            last = None
        elif direction == "in" and kind == "pose_update" and open_hold:
            point = payload.get("p_rel_m") or [0, 0, 0]
            if last:
                step = math.dist(point, last[0])
                open_hold.path_m += step
                dt = (at - last[1]) / 1000
                # A burst of delayed messages lands in the same millisecond; ignore those for speed.
                if dt >= 0.02:
                    open_hold.peak_speed_m_s = max(open_hold.peak_speed_m_s, step / dt)
            last = (point, at)
            open_hold.commanded_m = point
            open_hold.samples += 1
            open_hold.end_ms = at
        elif (
            direction == "out"
            and kind == "ack"
            and open_hold
            and payload.get("seq") == open_hold.seq
        ):
            reason = payload.get("reason", "")
            if payload.get("status") == "rejected":
                open_hold.ended_by = reason
            open_hold.end_ms = open_hold.end_ms or at
            open_hold = None
        elif direction == "disconnect_estop" and open_hold:
            open_hold.ended_by = "disconnect"
            open_hold = None
    return list(holds.values())


def parse_run_log(lines):
    """What the simulator measured per hold: where the arm really went, and how many steps it got."""
    stops = {}
    for line in lines:
        if line.startswith("S4 POSE STOP"):
            match = re.search(r"seq=(\d+) (\{.*\})", line)
            if not match:
                continue
            try:
                details = ast.literal_eval(match.group(2))
            except (ValueError, SyntaxError):
                continue
            stops.setdefault(int(match.group(1)), []).append(details)
    return stops


def merge(holds, stops):
    """Attach the simulator's numbers to each hold.

    Sequence numbers restart on every connection and the run logs come from several files, so a hold is
    matched to the first unused stop with the same seq whose final command is the same to within 5 mm.
    """
    used = set()
    for hold in sorted(holds, key=lambda h: h.start_ms):
        for index, details in enumerate(stops.get(hold.seq, [])):
            if (hold.seq, index) in used:
                continue
            if math.dist(details.get("webxr_delta_m", [9, 9, 9]), hold.commanded_m) < 0.005:
                used.add((hold.seq, index))
                hold.arm_m = details.get("actual_delta_m", hold.arm_m)
                hold.wall_s = details.get("wall_time_s", 0.0)
                hold.sim_steps = details.get("sim_steps", 0)
                hold.clamped = bool(details.get("workspace_clamped") or details.get("joint_limit_clamped"))
                break
    return holds


def suggest(holds):
    """Plain rules over the session. Returns (lines, facts) so the caller can print both."""
    real = [h for h in holds if h.commanded >= 0.02]
    if not real:
        return ["Not enough movement to judge: no hold commanded 2 cm or more."], {}
    measured = [h for h in real if h.wall_s > 0]
    facts = {
        "holds": len(real),
        "clamped": sum(h.clamped for h in real),
        "safety_stops": sum("tracking_safety_stop" in h.ended_by for h in real),
        "disconnects": sum(h.ended_by == "disconnect" for h in real),
    }
    speeds = [h.arm / h.wall_s for h in measured if h.wall_s >= 1.0 and h.arm >= 0.01]
    facts["arm_speed_cm_s"] = statistics.median(speeds) * 100 if speeds else None
    rates = [h.sim_steps / h.wall_s for h in measured if h.wall_s >= 1.0]
    facts["sim_steps_s"] = statistics.median(rates) if rates else None
    tracking = [
        h.tracking
        for h in measured
        if h.tracking is not None and not h.clamped and h.wall_s >= 1.0
    ]
    facts["tracking"] = statistics.median(tracking) if tracking else None
    wander = [h.wander for h in real if h.wander is not None and h.samples >= 15]
    facts["wander"] = statistics.median(wander) if wander else None
    facts["peak_hand_cm_s"] = max(h.peak_speed_m_s for h in real) * 100

    lines = []
    clamp_share = facts["clamped"] / facts["holds"]
    if clamp_share > 0.2:
        lines.append(
            f"Sensitivity: lower it by about 30%. {facts['clamped']} of {facts['holds']} holds hit the edge of the "
            "workspace, so the hand is asking for more travel than the arm has."
        )
    elif facts["safety_stops"]:
        lines.append(
            f"Sensitivity: lower it by about 30%, or move slower. {facts['safety_stops']} holds ended in the server's "
            f"safety stop: the command got more than {SERVER_LEAD_TRIP_M * 100:.0f} cm ahead of the arm."
        )
    elif facts["tracking"] is not None and facts["tracking"] < 0.6:
        lines.append(
            f"Sensitivity: lower it to about {max(facts['tracking'] / 0.8, 0.3):.1f} times the current value. "
            f"The arm covered only {facts['tracking'] * 100:.0f}% of what was asked."
        )
    else:
        lines.append(
            "Sensitivity: keep it. The arm reached what was asked without hitting an edge or a safety stop."
        )

    if facts["wander"] is None:
        lines.append("Smoothing: not enough samples to judge.")
    elif facts["wander"] > 1.5:
        lines.append(
            f"Smoothing: raise it by about 0.2. The command travelled {facts['wander']:.1f} times the straight "
            "distance, which is shake or correction on top of the intended move."
        )
    elif facts["wander"] < 1.1:
        lines.append(
            f"Smoothing: it can go down by about 0.1. The command is nearly a straight line "
            f"({facts['wander']:.2f} times the straight distance), so less filtering would cut lag."
        )
    else:
        lines.append(
            f"Smoothing: keep it. The command travelled {facts['wander']:.2f} times the straight distance."
        )

    if facts["arm_speed_cm_s"] is not None and facts["arm_speed_cm_s"] < 3:
        lines.append(
            f"Speed: the arm managed about {facts['arm_speed_cm_s']:.1f} cm/s"
            + (
                f" at {facts['sim_steps_s']:.0f} simulator steps per second"
                if facts["sim_steps_s"]
                else ""
            )
            + ". That is the simulator's limit, not a Settings value."
        )
    return lines, facts


def cm(vector):
    return ", ".join(f"{value * 100:+.1f}" for value in vector)


def report(holds, since_ms=0):
    holds = [
        h for h in sorted(holds, key=lambda h: h.start_ms) if h.start_ms >= since_ms
    ]
    out = ["# Hold report", "", f"{len(holds)} holds.", ""]
    out.append(
        "| Time | Asked (cm: x, y, z) | Arm moved (cm) | Reached | Seconds | Arm cm/s | Edge | Ended by |"
    )
    out.append("|---|---|---|---|---|---|---|---|")
    for hold in holds:
        reached = (
            f"{hold.tracking * 100:.0f}%"
            if hold.tracking is not None and hold.wall_s
            else "—"
        )
        speed = f"{hold.arm / hold.wall_s * 100:.1f}" if hold.wall_s >= 0.5 else "—"
        out.append(
            f"| {time.strftime('%H:%M:%S', time.localtime(hold.start_ms / 1000))} | {cm(hold.commanded_m)} | "
            f"{cm(hold.arm_m) if hold.wall_s else '—'} | {reached} | {hold.wall_s:.1f} | {speed} | "
            f"{'yes' if hold.clamped else ''} | {hold.ended_by} |"
        )
    lines, facts = suggest(holds)
    out += ["", "## Suggested settings", ""] + [f"- {line}" for line in lines]
    if facts:
        out += ["", "## Session numbers", ""]
        out.append(f"- Holds of 2 cm or more: {facts['holds']}")
        out.append(f"- Hit the workspace edge: {facts['clamped']}")
        out.append(f"- Ended by the server's safety stop: {facts['safety_stops']}")
        out.append(f"- Ended by a dropped connection: {facts['disconnects']}")
        out.append(f"- Fastest the hand asked for: {facts['peak_hand_cm_s']:.0f} cm/s")
    return "\n".join(out) + "\n"


def fetch(host, path):
    return subprocess.run(
        ["ssh", "-o", "BatchMode=yes", host, f"cat {path}"],
        capture_output=True,
        text=True,
        check=True,
        errors="replace",
    ).stdout.splitlines()


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--host", help="user@host to fetch both logs from over SSH")
    parser.add_argument("--run-log", help="local copy of the simulator run log")
    parser.add_argument("--net-log", help="local copy of the network log (JSON lines)")
    parser.add_argument("--since", help="HH:MM today; earlier holds are left out")
    args = parser.parse_args()
    if args.host:
        run_lines, net_lines = (
            fetch(args.host, REMOTE_RUN_LOG),
            fetch(args.host, REMOTE_NET_LOG),
        )
    elif args.run_log and args.net_log:
        run_lines = open(args.run_log, errors="replace").read().splitlines()
        net_lines = open(args.net_log, errors="replace").read().splitlines()
    else:
        parser.error("give --host, or both --run-log and --net-log")
    since_ms = 0
    if args.since:
        today = time.strftime("%Y-%m-%d")
        since_ms = int(
            time.mktime(time.strptime(f"{today} {args.since}", "%Y-%m-%d %H:%M")) * 1000
        )
    sys.stdout.write(
        report(merge(parse_net_log(net_lines), parse_run_log(run_lines)), since_ms)
    )


if __name__ == "__main__":
    main()
