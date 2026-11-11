#!/usr/bin/env python3
"""Scripted pick-and-place on the S4 simulator, repeated, to measure how often a grasp works.

It drives the server with its own jog commands through the dev relay (scripts/dev_relay.py), so the result
does not depend on the app or on a person's hand. Two grasps can be compared:

  --jaws front   the gripper as the scene starts it: the jaws open front to back
  --jaws side    the gripper rolled 90 degrees first: the jaws open left to right

Each run resets the scene, opens the gripper, moves the reported gripper point to a fixed offset from the
cube, closes, lifts, carries to the goal, lowers and opens. A run counts as placed when the server itself
reports the task done (it resets the cube when that happens).

Usage:
  scripts/sim_pick_place.py --jaws side --runs 5
  scripts/sim_pick_place.py --jaws front --runs 5 --url ws://127.0.0.1:8765

The offsets below were measured on 2026-11-11 for the S4 scene (cube 2.5 cm at 20 cm from the base). They
are positions of the point the server reports (the gripper link origin), not of the jaw tips.
"""

import argparse
import asyncio
import json
import math
import time

import websockets

# Reported gripper point minus cube centre when the jaws should close, metres, robot base frame.
GRASP_OFFSET = {"front": (0.0, 0.066, 0.0865), "side": (-0.007, 0.036, 0.088)}
ROLL_DEGREES = {"front": 0.0, "side": 90.0}
BASE_HEIGHT_M = 0.05  # the server reports the cube in the world frame and the arm in the base frame
HOME = (0.0206, -0.1414, 0.1599)


class Arm:
    def __init__(self, ws):
        self.ws, self.seq, self.state, self.rejects = ws, 0, {}, []
        self.speed = {"x": 0.008, "y": 0.006, "z": 0.005}  # metres per second, refined as jogs are observed

    async def send(self, kind, payload=None):
        self.seq += 1
        await self.ws.send(json.dumps(
            {"v": 1, "type": kind, "ts": int(time.time() * 1000), "seq": self.seq, "payload": payload or {}}
        ))

    async def read(self):
        async for raw in self.ws:
            message = json.loads(raw)
            if message["type"] == "state":
                self.state.update(message["payload"])
            elif message["type"] == "ack" and message["payload"].get("status") == "rejected":
                self.rejects.append(message["payload"].get("reason"))

    async def start(self):
        self.reader = asyncio.create_task(self.read())
        await self.send("hello", {"client": "phone", "name": "sim-pick-place"})
        await asyncio.sleep(1)

    def point(self):
        return list(self.state["ee_pos"])

    def cube(self):
        return list(self.state["object_pos"])

    async def reset(self):
        """A hung simulator answers busy and keeps reporting the old pose, so insist the reset happened."""
        # A dropped connection in the middle of a command leaves the server E-stopped.
        if self.state.get("estop"):
            await self.send("estop_reset")
            await asyncio.sleep(1.5)
        self.rejects.clear()
        await self.send("reset_scene")
        await asyncio.sleep(7)
        off = max(abs(a - b) for a, b in zip(self.point(), HOME))
        if off > 0.01 or "busy" in self.rejects:
            raise SystemExit(f"simulator did not reset: arm at {cm(self.point())} cm, refusals {self.rejects[-3:]}")

    async def held(self, start, payload, stop, seconds):
        await self.send(start, payload)
        end = time.time() + seconds
        while time.time() < end:
            await asyncio.sleep(0.14)
            await self.send("jog_keepalive")
        await self.send(stop)
        await asyncio.sleep(0.9)

    async def grip(self, action, seconds, step):
        await self.held("gripper_jog_start", {"action": action, "step": step}, "gripper_jog_stop", seconds)

    async def roll(self, degrees):
        """The server turns wrist_roll only through its phone-orientation hold, at most 60 degrees a hold."""
        left = degrees
        while abs(left) > 0.5:
            part = max(-45.0, min(45.0, left))
            half = math.radians(-part) / 2  # the server rolls by minus the rotation about the phone's y axis
            await self.send("orient_start", {
                "frame": "phone_body", "rate_hz": 30, "gain": 1.0, "deadband_deg": 0.0, "smoothing": 0.0,
            })
            # The server reports no joint angle and turns at most 0.01 rad per physics step, so the only way to
            # know the turn finished is to wait long enough for a slow simulator (15 s covers 6 steps a second).
            for _ in range(150):
                await self.send("orient_update", {"q_rel": [0.0, math.sin(half), 0.0, math.cos(half)]})
                await asyncio.sleep(0.1)
            await self.send("orient_stop")
            await asyncio.sleep(1.0)
            left -= part

    async def axis_to(self, axis, target, tolerance=0.002, tries=6):
        index = "xyz".index(axis)
        for _ in range(tries):
            error = target - self.point()[index]
            if abs(error) < tolerance:
                return
            before = self.point()[index]
            seconds = min(max(abs(error) / self.speed[axis], 0.25), 4.0)
            await self.held(
                "jog_start", {"axis": axis, "dir": 1 if error > 0 else -1, "step": "fine", "frame": "base"},
                "jog_stop", seconds,
            )
            moved = abs(self.point()[index] - before)
            if moved > 0.002:
                self.speed[axis] = 0.5 * self.speed[axis] + 0.5 * moved / seconds

    async def move_to(self, x, y, z, rounds=4, tolerance=0.0025):
        for _ in range(rounds):
            await self.axis_to("y", y)
            await self.axis_to("x", x)
            await self.axis_to("z", z)
            if max(abs(a - b) for a, b in zip(self.point(), (x, y, z))) < tolerance:
                return True
        return False


def cm(vector):
    return [round(value * 100, 1) for value in vector]


async def run(arm, jaws, number):
    await arm.reset()
    started, cube0, episode0 = time.time(), arm.cube(), arm.state.get("episode")
    goal = arm.state.get("goal_pos") or [0.075, -0.2, cube0[2]]
    cube_base = (cube0[0], cube0[1], cube0[2] - BASE_HEIGHT_M)
    target = [c + o for c, o in zip(cube_base, GRASP_OFFSET[jaws])]

    await arm.grip("open", 4, "coarse")
    await arm.axis_to("z", arm.point()[2] + 0.02)
    await arm.roll(ROLL_DEGREES[jaws])
    await arm.move_to(target[0], target[1], target[2] + 0.03)
    reached = await arm.move_to(*target)
    at = arm.point()
    if not reached:
        # Something is in the way (usually a jaw resting on the cube). Closing now only shoves the cube around.
        print(
            f"run {number}: jaws {jaws}, could not reach the grasp point "
            f"(off by {cm([a - b for a, b in zip(at, target)])} cm), {time.time() - started:.0f} s",
            flush=True,
        )
        return False, False
    await arm.grip("close", 15, "fine")
    # While the gripper is closed the server lets the arm sink about half a centimetre every time a command
    # ends, so correcting more often makes the position worse. Two rounds are enough to clear the table.
    await arm.move_to(at[0], at[1], at[2] + 0.03, rounds=2)
    await asyncio.sleep(1.0)
    rose = arm.cube()[2] - cube0[2]
    lifted = rose > 0.015
    placed = False
    if lifted:
        goal_x = at[0] + (goal[0] - cube0[0])
        await arm.move_to(goal_x, at[1], at[2] + 0.03, rounds=5)
        await arm.move_to(goal_x, at[1], at[2] + 0.002, rounds=3)
        await arm.grip("open", 5, "fine")
        await arm.axis_to("z", arm.point()[2] + 0.04)
        await asyncio.sleep(4)
        # On success the server starts a new episode and puts the cube back where it began.
        back = max(abs(a - b) for a, b in zip(arm.cube(), cube0)) < 0.004
        placed = bool(arm.state.get("task_success")) or (back and arm.state.get("episode") != episode0)
    print(
        f"run {number}: jaws {jaws}, reached the grasp point {'yes' if reached else 'no'} "
        f"(off by {cm([a - b for a, b in zip(at, target)])} cm), cube rose {rose * 100:.1f} cm, "
        f"lifted {'yes' if lifted else 'no'}, placed {'yes' if placed else 'no'}, {time.time() - started:.0f} s",
        flush=True,
    )
    return lifted, placed


async def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--jaws", choices=sorted(GRASP_OFFSET), required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--url", default="ws://127.0.0.1:8765")
    args = parser.parse_args()
    async with websockets.connect(args.url) as ws:
        arm = Arm(ws)
        await arm.start()
        results = [await run(arm, args.jaws, number + 1) for number in range(args.runs)]
    print(f"jaws {args.jaws}: lifted {sum(l for l, _ in results)} of {args.runs}, placed {sum(p for _, p in results)} of {args.runs}")


if __name__ == "__main__":
    asyncio.run(main())
