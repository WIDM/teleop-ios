#!/usr/bin/env python3
"""Fails when an xcodebuild test log shows that the system log was copied to the console of the app's unit tests.

Xcode starts the unit tests' process with OS_ACTIVITY_DT_MODE=YES unless the test plan sets it to NO. Every line
that any framework writes to the system log is then also written to that process's console. When whatever reads the
console stalls for a few seconds, a thread that writes such a line waits inside the write, and the networking threads
behind the tests' real sockets log on every connect and every close: the sockets stop, and a test's wait for a
connection runs out for a reason that has nothing to do with the app. The test plans set OS_ACTIVITY_DT_MODE to NO.

The check looks only at the unit tests' part of the log, for the lines the networking library writes: its function
names (nw_listener_socket_inbox_create_socket, nw_socket_output_finished) and the names its connection log gives each
connection ([C1], [C1:2], [C6 127.0.0.1:49367 ...]). That library writes only to the system log, so these reach the
console through the copy alone; XCTest, xcodebuild and the app's own output never contain them. A log without the
unit tests passes.

Usage: scripts/check-test-console.py <xcodebuild test log> ...
"""

import pathlib
import re
import sys

UNIT_TESTS = "TeleopTests.xctest"
BUNDLE_START = re.compile(r"Test Suite '([^']+\.xctest)' started")
BUNDLE_END = re.compile(r"Test Suite '([^']+\.xctest)' (?:passed|failed)")
NETWORK_LINE = re.compile(r"\bnw_[a-z]+_[a-z_]+|\[C\d+[\]: ]")
TEST_PLAN = re.compile(r"-testPlan (\S+)")


def check(path):
    text = pathlib.Path(path).read_text(errors="replace")
    plan = TEST_PLAN.search(text)
    plan_file = (
        f"TestPlans/{plan.group(1)}.xctestplan"
        if plan
        else "the test plan in TestPlans/ that ran"
    )
    found = []
    inside = False
    for number, line in enumerate(text.splitlines(), 1):
        start, end = BUNDLE_START.search(line), BUNDLE_END.search(line)
        if start:
            inside = start.group(1) == UNIT_TESTS
        if inside and NETWORK_LINE.search(line):
            found.append((number, line.strip()))
        if end:
            inside = False
    if not found:
        return True
    number, line = found[0]
    print(
        f"{path}: {len(found)} lines that the networking library writes to the system log were copied to the console "
        f"while the unit tests ran. The first, line {number}:\n"
        f"    {line[:300]}\n"
        "The copy is on when the unit tests start with OS_ACTIVITY_DT_MODE=YES, which Xcode sets unless the test plan "
        "says otherwise. While it is on, a console reader that stalls for a few seconds also stops the threads behind "
        "the tests' sockets, and tests that connect to the local server fail on a timeout the app did not cause.\n"
        f"Fix: {plan_file} must set the environment variable OS_ACTIVITY_DT_MODE to NO "
        "(defaultOptions, environmentVariableEntries)."
    )
    return False


if len(sys.argv) < 2:
    print(__doc__.strip().splitlines()[-1])
    sys.exit(2)
results = [check(path) for path in sys.argv[1:]]
sys.exit(0 if all(results) else 1)
