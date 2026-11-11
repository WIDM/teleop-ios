// Exhaustive state exploration of the real TeleopSession code.
// Breadth-first search over every reachable state, so each counterexample is a shortest path.
// Usage: SafetyCheck <ui-map.tsv> <known-findings.txt>
import Foundation
import TeleopCore

// Every TeleopAction case. scripts/drift.py fails if this list and the enum differ.
let actionTable: [(String, TeleopAction)] = [
    ("modeNext", .modeNext),
    ("cloudEnterStandby", .cloudEnterStandby),
    ("cloudSimulateFail", .cloudSimulateFail),
    ("cloudRecheck", .cloudRecheck),
    ("cloudUseOnSite", .cloudUseOnSite),
    ("permissionsContinue", .permissionsContinue),
    ("tutorialSkip", .tutorialSkip),
    ("tutorialNext1", .tutorialNext(step: 1)),
    ("tutorialNext2", .tutorialNext(step: 2)),
    ("tutorialNext3", .tutorialNext(step: 3)),
    ("openConnection", .openConnection),
    ("closeConnection", .closeConnection),
    ("openKeyboard", .openKeyboard),
    ("keyboardDone", .keyboardDone),
    ("changeServer", .changeServer),
    ("resetScene", .resetScene),
    ("switchMode", .switchMode),
    ("connect", .connect),
    ("disconnect", .disconnect),
    ("s1Back", .s1Back),
    ("reconnect", .reconnect),
    ("backToConnect", .backToConnect),
    ("back", .back),
    ("stop", .stop),
    ("releaseStop", .releaseStop),
    ("openSettings", .openSettings),
    ("settingsDone", .settingsDone),
    ("replayTutorial", .replayTutorial),
    ("openRecording", .openRecording),
    ("recordingAppeared", .recordingAppeared),
    ("recordingTick", .recordingTick),
    ("stopRecording", .stopRecording),
    ("saveRecording", .saveRecording),
    ("discardRecording", .discardRecording),
    ("openFallback", .openFallback),
    ("startFallbackRecording", .startFallbackRecording),
    ("gripperStartClosed", .gripperStart(.closed)),
    ("gripperStartOpen", .gripperStart(.open)),
    ("gripperEnd", .gripperEnd),
    ("turnStartPositive", .turnStart(.positive)),
    ("turnStartNegative", .turnStart(.negative)),
    ("turnStartTiltDown", .turnStart(.tiltDown)),
    ("turnStartTiltUp", .turnStart(.tiltUp)),
    ("turnEnd", .turnEnd),
    ("holdArmStart", .holdArmStart),
    ("holdArmEnd", .holdArmEnd),
    ("linkUpOpen", .linkUp(gripper: .open)),
    ("linkUpClosed", .linkUp(gripper: .closed)),
    ("linkUpUnknown", .linkUp(gripper: nil)),
    ("linkLost", .linkLost),
    ("linkLatencyNormal", .linkLatency(ms: 80)),
    ("linkLatencyAmber", .linkLatency(ms: 200)),
    ("linkLatencyBlocked", .linkLatency(ms: 420)),
]
// What the server can cause at any moment on a live link: LiveLinkController reports these from any route.
// A server-side E-stop arrives as stop; a rejected or untracked hold as holdArmEnd.
// A refused gripper jog arrives as gripperEnd, and a refused jaw turn as turnEnd; shippedActions already adds
// both while the control is held.
let linkEvents = ["linkUpOpen", "linkUpClosed", "linkUpUnknown", "linkLost", "linkLatencyNormal", "linkLatencyAmber", "linkLatencyBlocked", "stop"]
let actionsByName = Dictionary(uniqueKeysWithValues: actionTable.map { ($0.0, $0.1) })
// ModeSelectScreen changes the mode directly on the state, not through perform.
// toggleLiveLink is the Settings switch: AppModel.liveLink sends switchMode, then flips the flag.
let stateCalls = ["selectCloud", "selectOnSite", "toggleLiveLink"]
let recordingTickBound = 2

struct Node {
    var session: TeleopSession
    var loopPlaying: Bool
}

struct Step {
    let before: Node
    let action: String
    let after: Node
    let restartedLoop: Bool
}

struct Property {
    let id: String
    let promise: String
    let harm: String
}

let properties: [Property] = [
    Property(id: "S1", promise: "E-stop stays latched until releaseStop.", harm: "The arm could accept commands after STOP without a deliberate release."),
    Property(id: "S2", promise: "The arm starts moving only on holdArmStart while connected, not E-stopped and not latency-blocked.", harm: "The arm could move when the operator was told it cannot."),
    Property(id: "S3", promise: "The arm is never moving while E-stopped.", harm: "STOP would not stop the arm."),
    Property(id: "S4", promise: "The gripper changes only on gripperStart while connected, not E-stopped, not blocked and the arm not moving, or opens on resetScene while connected and not E-stopped, or takes the server's value when a live link comes up.", harm: "The gripper could drop or grab something unexpectedly."),
    Property(id: "S5", promise: "holdArmEnd always leaves the arm stopped.", harm: "Releasing the control would not stop the arm."),
    Property(id: "S6", promise: "The arm is moving only while connected and not latency-blocked.", harm: "The app could report or command motion over a lost or too-slow link."),
    Property(id: "S7", promise: "stop from any state ends E-stopped on S4 with the arm stopped.", harm: "STOP could fail in some state."),
    Property(id: "S8", promise: "The E-stop long buzz is never started while it is already playing.", harm: "HapticsController keeps only the newest loop player, so an older buzz may not be cancelled on release."),
    Property(id: "S9", promise: "The E-stop long buzz plays exactly while E-stop is latched.", harm: "The operator could lose the haptic signal for the current safety state."),
    Property(id: "S10", promise: "The gripper starts moving only on gripperStart, and is moving only while connected, not E-stopped, not latency-blocked and the arm is not moving.", harm: "The gripper could squeeze or drop something when the operator was told it cannot move."),
    Property(id: "S11", promise: "gripperEnd always leaves the gripper still.", harm: "Releasing the control would not stop the gripper."),
    Property(id: "S12", promise: "At most one of the arm hold, the gripper hold and the jaw turn is active.", harm: "The server runs one held control at a time, so the phone would show two controls working while only one is."),
    Property(id: "S13", promise: "A jaw turn is active only while connected and not E-stopped.", harm: "The jaws could keep turning after STOP or over a lost link."),
    Property(id: "S14", promise: "turnEnd always leaves the jaws still.", harm: "Releasing the control would not stop the jaws turning."),
    Property(id: "U1", promise: "On shipped screens, while E-stop is latched the user is only on S4 or a connection screen that leads back to it (P5, P7, S1, S7).", harm: "S4 is hidden, so the app looks ready while all control input is silently ignored."),
    Property(id: "U2", promise: "On shipped screens, S4 is shown only while E-stop is latched.", harm: "The app could claim E-stop when none is active."),
    Property(id: "U3", promise: "On shipped screens, a latched E-stop can always be released.", harm: "The operator could be stuck with no way back to control."),
    Property(id: "U4", promise: "On shipped screens, the arm is moving only while connected and not latency-blocked.", harm: "The app could report or command motion over a lost or too-slow link."),
    Property(id: "U5", promise: "Every shipped teleop screen (all but P1, P2, P3, S4) offers STOP.", harm: "The operator could have no STOP on a teleop screen."),
    Property(id: "U7", promise: "On shipped screens, the gripper is moving only while connected, not E-stopped, not latency-blocked and the arm is not moving.", harm: "Same as S10, reachable by tapping."),
    Property(id: "U8", promise: "On shipped screens, at most one held control is active, and a jaw turn is active only while connected and not E-stopped.", harm: "Same as S12 and S13, reachable by tapping."),
    Property(id: "U6", promise: "On shipped screens, the E-stop long buzz is never started while it is already playing.", harm: "HapticsController keeps only the newest loop player, so an older buzz may not be cancelled on release."),
]

func perform(_ name: String, on node: Node, shippedUI: Bool) -> (node: Node, restartedLoop: Bool)? {
    var session = node.session
    if name == "recordingTick", session.state.recordingElapsedSec >= recordingTickBound { return nil }
    switch name {
    case "selectCloud": session.state.selectCloud()
    case "selectOnSite": session.state.selectOnSite()
    case "toggleLiveLink":
        if session.state.emergencyStop { return nil }
        session.perform(.switchMode)
        session.state.liveLink.toggle()
    default: session.perform(actionsByName[name]!)
    }
    // ArmHoldModifier.onDisappear sends holdArmEnd when the hold area leaves the screen.
    if shippedUI, session.route != node.session.route, session.state.armMoving {
        session.perform(.holdArmEnd)
    }
    // HeldControlModifier.onDisappear and VolumeKeyModifier.onDisappear do the same for the gripper and the jaw turn.
    if shippedUI, session.route != node.session.route, session.state.gripperMoving != nil {
        session.perform(.gripperEnd)
    }
    if shippedUI, session.route != node.session.route, session.state.jawTurning != nil {
        session.perform(.turnEnd)
    }
    // Commands run in order, so a cancel only counts for a play that comes after it.
    var loop = node.loopPlaying
    var restarted = false
    for command in session.drainHaptics() {
        if command == .play(.emergencyLoop) {
            if loop { restarted = true }
            loop = true
        }
        if command == .cancel { loop = false }
    }
    return (Node(session: session, loopPlaying: loop), restarted)
}

// The stack is left out on purpose. See "Why the stack is left out" in SKILL.md.
// Not in key, because no action changes them: serverAddress sensitivity smoothing
// scripts/drift.py fails if FakeTeleopState gains a stored field that is in neither list.
struct StateKey: Hashable {
    let mode: TeleopMode
    let connected: Bool
    let heartbeatOk: Bool
    let physicalEstopOk: Bool
    let latencyMs: Int
    let commandsBlocked: Bool
    let gripper: GripperState
    let arm: ArmSide
    let tutorialDone: Bool
    let emergencyStop: Bool
    let isRecording: Bool
    let recordingElapsedSec: Int
    let developerMode: Bool
    let armMoving: Bool
    let gripperMoving: GripperState?
    let jawTurning: TurnDirection?
    let serverInputError: Bool
    let liveLink: Bool
    let route: Route
    let origin: Route?
    let loopPlaying: Bool
}

func key(_ node: Node) -> StateKey {
    let s = node.session.state
    let origin = Mirror(reflecting: node.session).children.first { $0.label == "connectionOrigin" }?.value as? Route
    return StateKey(
        mode: s.mode,
        connected: s.connected,
        heartbeatOk: s.heartbeatOk,
        physicalEstopOk: s.physicalEstopOk,
        latencyMs: s.latencyMs,
        commandsBlocked: s.commandsBlocked,
        gripper: s.gripper,
        arm: s.arm,
        tutorialDone: s.tutorialDone,
        emergencyStop: s.emergencyStop,
        isRecording: s.isRecording,
        recordingElapsedSec: s.recordingElapsedSec,
        developerMode: s.developerMode,
        armMoving: s.armMoving,
        gripperMoving: s.gripperMoving,
        jawTurning: s.jawTurning,
        serverInputError: s.serverInputError,
        liveLink: s.liveLink,
        route: node.session.route,
        origin: origin,
        loopPlaying: node.loopPlaying
    )
}

struct Violation {
    let parent: Int?
    let action: String?
    let detail: String
}

struct Exploration {
    var nodes: [Node] = []
    var parent: [Int?] = []
    var via: [String?] = []
    var edges: [[Int]] = []
    var transitions = 0
    var violations: [String: Violation] = [:]

    func path(to index: Int?, then action: String? = nil) -> [String] {
        var lines: [String] = []
        var current = index
        while let i = current, let name = via[i], let up = parent[i] {
            lines.append("\(name)  (\(nodes[up].session.route) -> \(nodes[i].session.route))")
            current = up
        }
        lines.reverse()
        if let action { lines.append(action) }
        return lines
    }
}

func explore(
    actions: (Node) -> [String],
    shippedUI: Bool,
    check: (Step) -> [(String, String)]
) -> Exploration {
    var result = Exploration()
    let start = Node(session: TeleopSession(), loopPlaying: false)
    var seen = [key(start): 0]
    result.nodes = [start]
    result.parent = [nil]
    result.via = [nil]
    result.edges = [[]]
    var head = 0
    while head < result.nodes.count {
        let node = result.nodes[head]
        for name in actions(node) {
            if shippedUI, name == "back", BackStackRules.previous(of: node.session.route) == nil {
                fatalError("ui-map sends back from \(node.session.route), which has no back rule. The stack can now change the route, so the state key in main.swift is no longer sound.")
            }
            guard let (next, restarted) = perform(name, on: node, shippedUI: shippedUI) else { continue }
            result.transitions += 1
            for (id, detail) in check(Step(before: node, action: name, after: next, restartedLoop: restarted))
            where result.violations[id] == nil {
                result.violations[id] = Violation(parent: head, action: name, detail: detail)
            }
            let k = key(next)
            if let existing = seen[k] {
                result.edges[head].append(existing)
            } else {
                let index = result.nodes.count
                seen[k] = index
                result.nodes.append(next)
                result.parent.append(head)
                result.via.append(name)
                result.edges.append([])
                result.edges[head].append(index)
            }
        }
        head += 1
    }
    return result
}

func linkOk(_ s: FakeTeleopState) -> Bool { s.connected && !s.commandsBlocked }

func heldControls(_ s: FakeTeleopState) -> Int {
    (s.armMoving ? 1 : 0) + (s.gripperMoving != nil ? 1 : 0) + (s.jawTurning != nil ? 1 : 0)
}

func sessionChecks(_ step: Step) -> [(String, String)] {
    let a = step.before.session.state
    let b = step.after.session.state
    var out: [(String, String)] = []
    if a.emergencyStop, !b.emergencyStop, step.action != "releaseStop" {
        out.append(("S1", "E-stop cleared by \(step.action)"))
    }
    if !a.armMoving, b.armMoving, !(step.action == "holdArmStart" && linkOk(a) && !a.emergencyStop) {
        out.append(("S2", "arm started by \(step.action): connected=\(a.connected) blocked=\(a.commandsBlocked) eStop=\(a.emergencyStop)"))
    }
    if b.emergencyStop, b.armMoving { out.append(("S3", "E-stop latched while armMoving is true")) }
    if a.gripper != b.gripper,
       !(step.action.hasPrefix("gripperStart") && linkOk(a) && !a.emergencyStop && !a.armMoving),
       !(step.action == "resetScene" && a.connected && !a.emergencyStop && b.gripper == .open),
       !(step.action.hasPrefix("linkUp") && a.liveLink) {
        out.append(("S4", "gripper changed by \(step.action)"))
    }
    if step.action == "holdArmEnd", b.armMoving { out.append(("S5", "armMoving still true after holdArmEnd")) }
    if b.gripperMoving != nil, a.gripperMoving != b.gripperMoving, !step.action.hasPrefix("gripperStart") {
        out.append(("S10", "gripper started by \(step.action)"))
    }
    if b.gripperMoving != nil, !(linkOk(b) && !b.emergencyStop && !b.armMoving) {
        out.append(("S10", "gripper moving with connected=\(b.connected) blocked=\(b.commandsBlocked) eStop=\(b.emergencyStop) arm=\(b.armMoving)"))
    }
    if step.action == "gripperEnd", b.gripperMoving != nil { out.append(("S11", "gripper still moving after gripperEnd")) }
    if heldControls(b) > 1 {
        out.append(("S12", "held controls: arm=\(b.armMoving) gripper=\(String(describing: b.gripperMoving)) turn=\(String(describing: b.jawTurning))"))
    }
    if b.jawTurning != nil, !(b.connected && !b.emergencyStop) {
        out.append(("S13", "jaws turning with connected=\(b.connected) eStop=\(b.emergencyStop)"))
    }
    if step.action == "turnEnd", b.jawTurning != nil { out.append(("S14", "jaws still turning after turnEnd")) }
    if b.armMoving, !linkOk(b) {
        out.append(("S6", "armMoving is true with connected=\(b.connected) blocked=\(b.commandsBlocked)"))
    }
    if step.action == "stop", !(b.emergencyStop && !b.armMoving && step.after.session.route == .s4) {
        out.append(("S7", "after stop: eStop=\(b.emergencyStop) arm=\(b.armMoving) route=\(step.after.session.route)"))
    }
    if step.restartedLoop {
        out.append(("S8", "second emergencyLoop started without a cancel"))
    }
    if step.after.loopPlaying != b.emergencyStop {
        out.append(("S9", "loopPlaying=\(step.after.loopPlaying) while eStop=\(b.emergencyStop)"))
    }
    return out
}

let screensWhileEStopped: Set<Route> = [.s4, .p5, .p7, .s1, .s7]

func uiChecks(_ step: Step) -> [(String, String)] {
    let b = step.after.session.state
    let route = step.after.session.route
    var out: [(String, String)] = []
    if b.emergencyStop, !screensWhileEStopped.contains(route) {
        out.append(("U1", "E-stop latched while showing \(route)"))
    }
    if route == .s4, !b.emergencyStop { out.append(("U2", "S4 shown with no E-stop latched")) }
    if b.armMoving, !linkOk(b) {
        out.append(("U4", "armMoving is true with connected=\(b.connected) blocked=\(b.commandsBlocked)"))
    }
    if step.restartedLoop {
        out.append(("U6", "second emergencyLoop started without a cancel"))
    }
    if b.gripperMoving != nil, !(linkOk(b) && !b.emergencyStop && !b.armMoving) {
        out.append(("U7", "gripper moving with connected=\(b.connected) blocked=\(b.commandsBlocked) eStop=\(b.emergencyStop) arm=\(b.armMoving)"))
    }
    if heldControls(b) > 1 {
        out.append(("U8", "held controls: arm=\(b.armMoving) gripper=\(String(describing: b.gripperMoving)) turn=\(String(describing: b.jawTurning))"))
    }
    if b.jawTurning != nil, !(b.connected && !b.emergencyStop) {
        out.append(("U8", "jaws turning with connected=\(b.connected) eStop=\(b.emergencyStop)"))
    }
    return out
}

func loadUIMap(_ path: String) throws -> [Route: [String]] {
    let routes = Dictionary(uniqueKeysWithValues: Route.allCases.map { ("\($0)", $0) })
    var map: [Route: [String]] = [:]
    for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
        let columns = line.split(separator: "\t").map(String.init)
        guard columns.count == 3, let route = routes[columns[0]] else { fatalError("Bad ui-map line: \(line)") }
        let names = columns[2].split(separator: ",").map(String.init)
        for name in names where actionsByName[name] == nil && !stateCalls.contains(name) {
            fatalError("Unknown action in ui-map: \(name)")
        }
        map[route] = names
    }
    for route in Route.allCases where map[route] == nil { fatalError("ui-map has no row for \(route)") }
    return map
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("Usage: SafetyCheck <ui-map.tsv> <known-findings.txt>") }
let uiMap = try loadUIMap(arguments[1])
let known = Set(
    try String(contentsOfFile: arguments[2], encoding: .utf8)
        .split(separator: "\n")
        .filter { !$0.hasPrefix("#") }
        .compactMap { $0.split(separator: " ").first.map(String.init) }
)

let allNames = actionTable.map(\.0) + stateCalls
let sessionRun = explore(actions: { _ in allNames }, shippedUI: false, check: sessionChecks)
// RootView sends these from any route: the recording timer, and holdArmEnd when the app leaves the foreground.
func shippedActions(_ node: Node) -> [String] {
    var names = uiMap[node.session.route]!
    if node.session.state.isRecording { names.append("recordingTick") }
    if node.session.state.armMoving, !names.contains("holdArmEnd") { names.append("holdArmEnd") }
    if node.session.state.gripperMoving != nil, !names.contains("gripperEnd") { names.append("gripperEnd") }
    if node.session.state.jawTurning != nil, !names.contains("turnEnd") { names.append("turnEnd") }
    if node.session.state.liveLink { names += linkEvents.filter { !names.contains($0) } }
    return names
}
var uiRun = explore(actions: shippedActions, shippedUI: true, check: uiChecks)

// U3: walk backward from every state with no E-stop latched.
var incoming = [[Int]](repeating: [], count: uiRun.nodes.count)
for (from, targets) in uiRun.edges.enumerated() { for to in targets { incoming[to].append(from) } }
var canRelease = uiRun.nodes.map { !$0.session.state.emergencyStop }
var queue = canRelease.indices.filter { canRelease[$0] }
while let index = queue.popLast() {
    for from in incoming[index] where !canRelease[from] {
        canRelease[from] = true
        queue.append(from)
    }
}
if let stuck = canRelease.firstIndex(of: false) {
    uiRun.violations["U3"] = Violation(parent: stuck, action: nil, detail: "no path to release from \(uiRun.nodes[stuck].session.route)")
}
// U5: read straight from the screen map.
let noStopAllowed: Set<Route> = [.p1, .p2, .p3, .s4]
for route in Route.allCases where !noStopAllowed.contains(route) && !uiMap[route]!.contains("stop") {
    uiRun.violations["U5"] = uiRun.violations["U5"] ?? Violation(parent: nil, action: nil, detail: "\(route) has no STOP in ui-map.tsv")
}

print("Every action in every state: \(sessionRun.nodes.count) states, \(sessionRun.transitions) transitions")
print("Shipped screens only: \(uiRun.nodes.count) states, \(uiRun.transitions) transitions")
print("")

var failed = false
for property in properties {
    let run = property.id.hasPrefix("S") ? sessionRun : uiRun
    if let violation = run.violations[property.id] {
        let isKnown = known.contains(property.id)
        if !isKnown { failed = true }
        print("\(isKnown ? "KNOWN" : "FAIL") \(property.id): \(property.promise)")
        print("  Harm: \(property.harm)")
        print("  Found: \(violation.detail)")
        for (number, line) in run.path(to: violation.parent, then: violation.action).enumerated() {
            print("  \(number + 1). \(line)")
        }
    } else if known.contains(property.id) {
        failed = true
        print("STALE \(property.id): listed in known-findings.txt but no longer breaks: \(property.promise)")
    } else {
        print("PASS \(property.id): \(property.promise)")
    }
}
exit(failed ? 1 : 0)
