/// Back targets for Mockup v2 iOS.
/// Parent override: a status chip opens P5 (not S1). S1 is entered from P5 "Change server";
/// S1 Back returns to P5.
public enum BackStackRules {
    public static func previous(of route: Route) -> Route? {
        switch route {
        case .p5, .p6: return .p4
        case .p7: return .p5
        case .t1: return .s2
        case .t2: return .t1
        case .t3: return .t2
        case .s1: return .p5
        case .s4, .s5, .s6: return .p4
        case .s2, .p4: return nil
        }
    }

    /// Screens that drive the robot. Losing a live link here returns to S1.
    public static let controlRoutes: Set<Route> = [.p4, .p6, .s5]

    public static func handlesBack(_ route: Route) -> Bool {
        previous(of: route) != nil
    }

    /// Forward edges used for reachability from S2, where a fresh install opens. In-place actions are not edges.
    public static let forwardEdges: [Route: [Route]] = [
        .s2: [.t1, .p5],
        .t1: [.t2, .p4, .p5, .s6, .s4],
        .t2: [.t3, .p4, .p5, .s4],
        .t3: [.p4, .p5, .s4],
        .p4: [.p5, .s5, .s6, .s4, .s1],
        .p5: [.p4, .p6, .p7, .s1, .s6, .s4],
        .p6: [.p5, .p4, .s6, .s4, .s1],
        .p7: [.p5, .p4, .s6, .s4],
        .s1: [.p5, .s4],
        .s4: [.p4, .p5],
        .s5: [.p5, .s6, .s4, .s1],
        .s6: [.p4, .t1, .s4],
    ]

    public static func reachable(from start: Route = .s2) -> Set<Route> {
        var seen = Set<Route>()
        var queue = [start]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard seen.insert(current).inserted else { continue }
            for next in forwardEdges[current] ?? [] where !seen.contains(next) {
                queue.append(next)
            }
        }
        return seen
    }
}
