"""Run with: python3 -m unittest scripts/test_analyze_holds.py"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import analyze_holds as tool  # noqa: E402


def net(direction, kind, seq, payload, at):
    return json.dumps({"server_ts": at, "direction": direction, "message": {"type": kind, "seq": seq, "payload": payload}})


def hold_lines(seq, start, points, rejected=None, step_ms=33):
    """One hold as the network log has it: start, updates, then the final ack for the start."""
    lines = [net("in", "pose_start", seq, {}, start)]
    for index, point in enumerate(points):
        lines.append(net("in", "pose_update", seq + 1 + index, {"p_rel_m": point}, start + (index + 1) * step_ms))
    status = {"seq": seq, "status": "rejected", "reason": rejected} if rejected else {"seq": seq, "status": "ok", "reason": "pose_stopped"}
    lines.append(net("out", "ack", seq, status, start + (len(points) + 2) * step_ms))
    return lines


def stop_line(seq, commanded, arm, wall=2.0, steps=18, clamped=False):
    details = {"webxr_delta_m": commanded, "actual_delta_m": arm, "wall_time_s": wall, "sim_steps": steps,
               "workspace_clamped": clamped, "joint_limit_clamped": False}
    return f"S4 POSE STOP seq={seq} {details}"


def straight(distance, samples=30):
    return [[distance * (i + 1) / samples, 0, 0] for i in range(samples)]


class ParseTests(unittest.TestCase):
    def test_hold_gets_command_path_and_speed(self):
        hold = tool.parse_net_log(hold_lines(2, 1000, straight(0.06)))[0]
        self.assertAlmostEqual(hold.commanded, 0.06, places=4)
        self.assertAlmostEqual(hold.path_m, 0.058, places=3)
        self.assertAlmostEqual(hold.peak_speed_m_s, 0.002 / 0.033, places=3)
        self.assertEqual(hold.ended_by, "release")

    def test_rejected_hold_keeps_the_server_reason(self):
        hold = tool.parse_net_log(hold_lines(2, 1000, straight(0.12), rejected="pose_tracking_safety_stop"))[0]
        self.assertEqual(hold.ended_by, "pose_tracking_safety_stop")

    def test_disconnect_closes_the_hold(self):
        lines = hold_lines(2, 1000, straight(0.03))[:-1] + [json.dumps({"server_ts": 3000, "direction": "disconnect_estop"})]
        self.assertEqual(tool.parse_net_log(lines)[0].ended_by, "disconnect")

    def test_garbage_lines_are_skipped(self):
        self.assertEqual(tool.parse_net_log(["not json", "{}"]), [])
        self.assertEqual(tool.parse_run_log(["S4 POSE STOP seq=2 {broken", "other line"]), {})

    def test_repeated_seq_matches_by_final_command(self):
        # Two connections both used seq 2; the run log lists them in the other order.
        holds = tool.parse_net_log(hold_lines(2, 1000, straight(0.03)) + hold_lines(2, 9000, straight(0.06)))
        stops = tool.parse_run_log([stop_line(2, [0.06, 0, 0], [0.05, 0, 0]), stop_line(2, [0.03, 0, 0], [0.03, 0, 0])])
        first, second = tool.merge(holds, stops)
        self.assertAlmostEqual(first.arm, 0.03)
        self.assertAlmostEqual(second.arm, 0.05)

    def test_same_command_twice_uses_each_stop_once(self):
        holds = tool.parse_net_log(hold_lines(2, 1000, straight(0.03)) + hold_lines(2, 9000, straight(0.03)))
        stops = tool.parse_run_log([stop_line(2, [0.03, 0, 0], [0.01, 0, 0]), stop_line(2, [0.03, 0, 0], [0.02, 0, 0])])
        first, second = tool.merge(holds, stops)
        self.assertAlmostEqual(first.arm, 0.01)
        self.assertAlmostEqual(second.arm, 0.02)


class SuggestTests(unittest.TestCase):
    def session(self, specs):
        net_lines, run_lines = [], []
        for index, spec in enumerate(specs):
            seq, start = 2 + index * 100, 1000 + index * 10000
            points = spec.get("points", straight(spec.get("asked", 0.06)))
            net_lines += hold_lines(seq, start, points, rejected=spec.get("rejected"))
            if "arm" in spec:
                run_lines.append(stop_line(seq, points[-1], [spec["arm"], 0, 0], clamped=spec.get("clamped", False)))
        return tool.merge(tool.parse_net_log(net_lines), tool.parse_run_log(run_lines))

    def test_clean_session_keeps_sensitivity(self):
        lines, facts = tool.suggest(self.session([{"arm": 0.055}] * 4))
        self.assertIn("Sensitivity: keep it", lines[0])
        self.assertEqual(facts["safety_stops"], 0)

    def test_edge_hits_lower_sensitivity(self):
        lines, _ = tool.suggest(self.session([{"arm": 0.02, "clamped": True}] * 2 + [{"arm": 0.055}] * 2))
        self.assertIn("lower it by about 30%", lines[0])
        self.assertIn("workspace", lines[0])

    def test_safety_stops_are_named(self):
        lines, facts = tool.suggest(self.session([{"asked": 0.15, "rejected": "pose_tracking_safety_stop"}, {"arm": 0.055}] * 2))
        self.assertEqual(facts["safety_stops"], 2)
        self.assertIn("safety stop", lines[0])

    def test_arm_far_behind_scales_sensitivity(self):
        lines, facts = tool.suggest(self.session([{"arm": 0.024}] * 4))
        self.assertAlmostEqual(facts["tracking"], 0.4, places=2)
        self.assertIn("0.5 times", lines[0])

    def test_shaky_command_raises_smoothing(self):
        shaky = [[0.002 * (i + 1) + (0.004 if i % 2 else -0.004), 0, 0] for i in range(30)]
        lines, facts = tool.suggest(self.session([{"points": shaky, "arm": 0.05}] * 3))
        self.assertGreater(facts["wander"], 1.5)
        self.assertIn("raise it", lines[1])

    def test_straight_command_can_lower_smoothing(self):
        lines, _ = tool.suggest(self.session([{"arm": 0.055}] * 3))
        self.assertIn("can go down", lines[1])

    def test_no_real_movement_says_so(self):
        lines, facts = tool.suggest(self.session([{"asked": 0.005, "arm": 0.005}]))
        self.assertIn("Not enough movement", lines[0])
        self.assertEqual(facts, {})

    def test_report_has_one_row_per_hold_and_respects_since(self):
        holds = self.session([{"arm": 0.055}] * 3)
        self.assertEqual(tool.report(holds).count("| release |"), 3)
        self.assertEqual(tool.report(holds, since_ms=5000).count("| release |"), 2)


if __name__ == "__main__":
    unittest.main()
