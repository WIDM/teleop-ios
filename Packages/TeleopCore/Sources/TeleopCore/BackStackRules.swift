/// Back targets for Mockup v2 iOS.
/// Parent override: a status chip opens P5 (not S1). S1 is entered from P5 "Change server";
/// S1 Back returns to P5.
public enum BackStackRules {
    public static func previous(of route: Route) -> Route? {
        switch route {
        case .p2, .p3: return .p1
        case .p5, .p6: return .p4
        case .p7: return .p5
        case .t1: return .s2
        case .t2: return .t1
        case .t3: return .t2
        case .s1: return .p5
        case .s2: return .p2
        case .s3a, .s3m, .s4, .s5, .s6: return .p4
        case .s3b: return .s3a
        case .s5a: return .s5
        case .s7: return .s1
        case .p1, .p4: return nil
        }
    }

    /// Screens that drive the robot. Losing a live link here opens S7.
    public static let controlRoutes: Set<Route> = [.p4, .p6, .s3a, .s3b, .s3m, .s5, .s5a]

    public static func handlesBack(_ route: Route) -> Bool {
        previous(of: route) != nil
    }

    /// Forward edges used for reachability from P1. In-place actions are not edges.
    public static let forwardEdges: [Route: [Route]] = [
        .p1: [.p2, .p3, .s2],
        .p2: [.s2, .p1],
        .p3: [.p2, .p1],
        .s2: [.t1, .p5],
        .t1: [.t2, .p4, .p5, .s3a, .s6, .s4],
        .t2: [.t3, .p4, .p5, .s4],
        .t3: [.p4, .p5, .s4],
        .p4: [.p5, .s3a, .s3m, .s5, .s6, .s4, .s7],
        .p5: [.p4, .p6, .p7, .s1, .s3a, .s6, .s4],
        .p6: [.p5, .p4, .s3a, .s6, .s4, .s7],
        .p7: [.p5, .p4, .s3a, .s6, .s4],
        .s1: [.p5, .s7, .p1, .s4],
        .s3a: [.s3b, .p5, .s6, .s4, .s7],
        .s3b: [.p4, .p5, .s4, .s7],
        .s3m: [.p4, .p5, .s3a, .s6, .s4, .s7],
        .s4: [.p4, .p5],
        .s5: [.s5a, .p5, .s6, .s4, .s7],
        .s5a: [.s3b, .p5, .s6, .s4, .s7],
        .s6: [.p4, .t1, .s4, .p1],
        .s7: [.s1, .p5, .s4],
    ]

    public static func reachable(from start: Route = .p1) -> Set<Route> {
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
