#!/usr/bin/env python3
"""Record what the real server answers, scenario by scenario, as seen by a client.

Each scenario becomes <name>.jsonl in the server model's test recordings. A line is
{"t": seconds since the scenario began, "dir": "out" (client to server) or "in",
"msg": the message}. Runs through the dev relay on this Mac, so it moves the live
simulator's arm a few centimetres: run it only when nobody else is using it.

    python3 scripts/trace_scenarios.py                  # every scenario, in order
    python3 scripts/trace_scenarios.py s05_pose_watchdog

See docs/TESTING.md for adding a recording to the conformance tests.
"""

import asyncio
import json
import math
import pathlib
import sys
import time

import websockets

URL = "ws://127.0.0.1:8765"
OUT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "Packages/TeleopCore/Tests/TeleopServerModelTests/Recordings"
)
POSE_START = {
    "frame": "webxr_local",
    "rate_hz": 30,
    "control_mode": "translation",
    "gain": 1.0,
    "deadband_deg": 2.5,
    "smoothing": 0.3,
}
ORIENT_START = {
    "frame": "phone_body",
    "rate_hz": 30,
    "gain": 1.0,
    "deadband_deg": 0.0,
    "smoothing": 0.0,
}


class Client:
    def __init__(self, ws):
        self.ws = ws
        self.seq = 0
        self.state = {}
        self.lines = None
        self.began = 0.0
        self.task = asyncio.create_task(self.reader())

    def note(self, direction, message):
        if self.lines is not None:
            self.lines.append(
                {
                    "t": round(time.time() - self.began, 3),
                    "dir": direction,
                    "msg": message,
                }
            )

    async def send(self, kind, payload=None, raw=None):
        self.seq += 1
        message = raw or {
            "v": 1,
            "type": kind,
            "ts": int(time.time() * 1000),
            "seq": self.seq,
            "payload": payload or {},
        }
        self.note("out", message)
        await self.ws.send(json.dumps(message))
        return self.seq

    async def reader(self):
        try:
            async for raw in self.ws:
                message = json.loads(raw)
                if message.get("type") == "state":
                    self.state.update(message["payload"])
                self.note("in", message)
        except websockets.ConnectionClosed:
            pass

    async def settle(self):
        """Back to a known idle scene, outside the trace."""
        if self.state.get("estop"):
            await self.send("estop_reset")
            await asyncio.sleep(1.5)
        await self.send("reset_scene")
        await asyncio.sleep(7)

    async def pose(self, seconds, target, stop=True):
        await self.send("pose_start", POSE_START)
        steps = max(int(seconds * 30), 1)
        for index in range(1, steps + 1):
            point = [round(value * index / steps, 4) for value in target]
            await self.send(
                "pose_update",
                {"p_rel_m": point, "q_rel": [0, 0, 0, 1], "gripper_delta": 0},
            )
            await asyncio.sleep(1 / 30)
        if stop:
            await self.send("pose_stop")

    async def keepalive(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            await asyncio.sleep(0.14)
            await self.send("jog_keepalive")


async def idle(c):
    await asyncio.sleep(2.0)
    await c.send("test")
    await asyncio.sleep(1.0)


async def pose_hold(c):
    await c.pose(2.0, [0.0, 0.02, 0.0])
    await asyncio.sleep(2.0)


async def busy_handoff(c):
    await c.pose(1.0, [0.0, 0.0, 0.0])
    await c.send("gripper_jog_start", {"action": "open", "step": "coarse"})
    await asyncio.sleep(1.0)
    await c.send("gripper_jog_start", {"action": "open", "step": "coarse"})
    await c.keepalive(1.0)
    await c.send("gripper_jog_stop")
    await asyncio.sleep(1.5)


async def stop_then_reset(c):
    await c.pose(1.0, [0.0, 0.0, 0.0])
    await c.send("reset_scene")
    await asyncio.sleep(1.5)
    await c.send("reset_scene")
    await asyncio.sleep(7.0)


async def pose_watchdog(c):
    await c.pose(1.0, [0.0, 0.01, 0.0], stop=False)
    await asyncio.sleep(2.5)


async def estop_in_hold(c):
    await c.pose(1.0, [0.0, 0.01, 0.0], stop=False)
    await c.send("estop")
    await asyncio.sleep(1.0)
    await c.send("pose_start", POSE_START)
    await asyncio.sleep(0.5)
    await c.send("gripper_jog_start", {"action": "open", "step": "coarse"})
    await asyncio.sleep(0.5)
    await c.send("estop_reset")
    await asyncio.sleep(1.5)
    await c.pose(0.5, [0.0, 0.0, 0.0])
    await asyncio.sleep(1.5)


async def estop_then_reset_scene(c):
    await c.send("estop")
    await asyncio.sleep(1.0)
    await c.send("estop_reset")
    await asyncio.sleep(0.2)
    await c.send("estop")
    await asyncio.sleep(1.0)
    await c.send("reset_scene")
    await asyncio.sleep(7.0)


async def gripper_jog(c):
    await c.send("gripper_jog_start", {"action": "open", "step": "coarse"})
    await c.keepalive(2.0)
    await c.send("gripper_jog_stop")
    await asyncio.sleep(1.5)
    await c.send("gripper_jog_start", {"action": "close", "step": "coarse"})
    await c.keepalive(2.0)
    await c.send("gripper_jog_stop")
    await asyncio.sleep(1.5)


async def gripper_watchdog(c):
    await c.send("gripper_jog_start", {"action": "open", "step": "coarse"})
    await asyncio.sleep(2.5)


async def orient_hold(c):
    await c.send("orient_start", ORIENT_START)
    for index in range(1, 61):
        half = math.radians(-20.0 * index / 60) / 2
        await c.send(
            "orient_update",
            {"q_rel": [0, round(math.sin(half), 6), 0, round(math.cos(half), 6)]},
        )
        await asyncio.sleep(1 / 30)
    await c.send("orient_stop")
    await asyncio.sleep(2.0)


async def buttons(c):
    await c.send("mode", {"step": "fine"})
    await asyncio.sleep(0.5)
    await c.send("jog_start", {"axis": "x", "dir": 1, "step": "fine", "frame": "base"})
    await c.keepalive(1.0)
    await c.send("jog_stop")
    await asyncio.sleep(1.5)
    await c.send("move_delta", {"axis": "z", "dir": 1, "step": "fine", "frame": "base"})
    await asyncio.sleep(4.0)
    await c.send(
        "move_delta", {"axis": "z", "dir": -1, "step": "coarse", "frame": "base"}
    )
    await c.send("move_delta", {"axis": "z", "dir": 1, "step": "fine", "frame": "base"})
    await asyncio.sleep(8.0)
    await c.send("gripper", {"action": "open"})
    await asyncio.sleep(8.0)
    await c.send("joint_jog_start", {"joint": "wrist_flex", "dir": 1, "step": "fine"})
    await c.keepalive(1.0)
    await c.send("joint_jog_stop")
    await asyncio.sleep(1.5)
    await c.send("joint_delta", {"joint": "wrist_flex", "dir": -1, "step": "fine"})
    await asyncio.sleep(4.0)


async def invalid(c):
    await c.send(
        "pose_update",
        {"p_rel_m": [0, 0, 0], "q_rel": [0, 0, 0, 1], "gripper_delta": 0},
    )
    await asyncio.sleep(0.4)
    await c.send("pose_stop")
    await asyncio.sleep(0.4)
    await c.send("jog_keepalive")
    await asyncio.sleep(0.4)
    await c.send("jog_start", {"axis": "rx", "dir": 1, "step": "fine", "frame": "base"})
    await asyncio.sleep(0.4)
    await c.send("no_such_type")
    await asyncio.sleep(0.4)
    await c.send("pose_start", {"frame": "webxr_local"})
    await asyncio.sleep(0.4)
    await c.send("estop_reset")
    await asyncio.sleep(0.4)
    await c.send(
        None, raw={"v": 9, "type": "hello", "ts": 1, "seq": 9999, "payload": {}}
    )
    await asyncio.sleep(0.4)
    await c.send("gripper_jog_start", {"action": "squeeze", "step": "coarse"})
    await asyncio.sleep(1.0)


async def workspace_edge(c):
    await c.pose(6.0, [0.0, 0.0, -0.30])
    await asyncio.sleep(2.0)


async def gripper_step(c):
    await c.send("gripper", {"action": "open"})
    await asyncio.sleep(9.0)
    await c.send("gripper", {"action": "close"})
    await asyncio.sleep(9.0)


async def wrist_jog(c):
    await c.send("joint_jog_start", {"joint": "wrist_flex", "dir": 1, "step": "fine"})
    await c.keepalive(1.0)
    await c.send("joint_jog_stop")
    await asyncio.sleep(1.5)
    await c.send("joint_delta", {"joint": "wrist_flex", "dir": -1, "step": "fine"})
    await asyncio.sleep(5.0)


async def jog_axes(c):
    for axis, direction in (("y", -1), ("z", 1), ("x", -1)):
        await c.send(
            "jog_start", {"axis": axis, "dir": direction, "step": "coarse", "frame": "base"}
        )
        await c.keepalive(0.8)
        await c.send("jog_stop")
        await asyncio.sleep(1.2)
    await c.send("jog_start", {"axis": "z", "dir": 1, "step": "fine", "frame": "base"})
    await asyncio.sleep(2.5)


SCENARIOS = [
    ("s01_idle", idle),
    ("s02_pose_hold", pose_hold),
    ("s03_busy_handoff", busy_handoff),
    ("s04_stop_then_reset", stop_then_reset),
    ("s05_pose_watchdog", pose_watchdog),
    ("s06_estop_in_hold", estop_in_hold),
    ("s07_estop_then_reset_scene", estop_then_reset_scene),
    ("s08_gripper_jog", gripper_jog),
    ("s09_gripper_watchdog", gripper_watchdog),
    ("s10_orient_hold", orient_hold),
    # The coarse move down failed its tolerance in the 2026-11-11 recording, hence the name.
    ("s11_buttons_step_fails", buttons),
    ("s12_invalid", invalid),
    ("s13_workspace_edge", workspace_edge),
    ("s15_gripper_step", gripper_step),
    ("s16_wrist_jog", wrist_jog),
    ("s17_jog_axes", jog_axes),
]


async def run(names):
    OUT.mkdir(exist_ok=True)
    async with websockets.connect(URL) as ws:
        client = Client(ws)
        # The greeting is a scenario of its own: hello, welcome, first states.
        client.lines, client.began = [], time.time()
        await client.send("hello", {"client": "phone", "name": "thomas-app"})
        await asyncio.sleep(1.5)
        if not names or "s00_hello" in names:
            write("s00_hello", client.lines)
        client.lines = None
        for name, scenario in SCENARIOS:
            if names and name not in names:
                continue
            await client.settle()
            client.lines, client.began = [], time.time()
            await scenario(client)
            write(name, client.lines)
            client.lines = None
        await client.settle()

    if not names or "s14_disconnect_in_hold" in names:
        async with websockets.connect(URL) as ws:
            client = Client(ws)
            await client.send("hello", {"client": "phone", "name": "thomas-app"})
            await asyncio.sleep(1.0)
            await client.settle()
            client.lines, client.began = [], time.time()
            await client.pose(1.0, [0.0, 0.01, 0.0], stop=False)
            lines, began = client.lines, client.began
        await asyncio.sleep(2.0)
        async with websockets.connect(URL) as ws:
            client = Client(ws)
            client.lines, client.began = lines, began
            client.note("out", {"type": "(socket closed, then reopened)"})
            await client.send("hello", {"client": "phone", "name": "thomas-app"})
            await asyncio.sleep(1.5)
            await client.send("estop_reset")
            await asyncio.sleep(1.5)
            write("s14_disconnect_in_hold", client.lines)
            client.lines = None
            await client.settle()


def write(name, lines):
    path = OUT / f"{name}.jsonl"
    path.write_text(
        "".join(json.dumps(line, ensure_ascii=False) + "\n" for line in lines)
    )
    acks = [
        (line["msg"]["payload"].get("status"), line["msg"]["payload"].get("reason"))
        for line in lines
        if line["dir"] == "in" and line["msg"].get("type") == "ack"
    ]
    states = sum(
        1
        for line in lines
        if line["dir"] == "in" and line["msg"].get("type") == "state"
    )
    print(f"{name}: {len(lines)} lines, {states} states, acks={acks}", flush=True)


if __name__ == "__main__":
    asyncio.run(run(sys.argv[1:]))
