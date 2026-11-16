/// Back stack with the same semantics as the Android nav graph:
/// navigate pushes unless the destination is already on top; back pops to the
/// rule-defined previous route when it is on the stack, otherwise pushes it.
public struct TeleopNavigator: Equatable, Sendable {
    public private(set) var stack: [Route]

    public init(start: Route = .s2) {
        stack = [start]
    }

    public var current: Route { stack[stack.count - 1] }

    public mutating func navigate(to route: Route) {
        guard current != route else { return }
        stack.append(route)
    }

    public mutating func back() {
        guard let previous = BackStackRules.previous(of: current) else {
            if stack.count > 1 { stack.removeLast() }
            return
        }
        if let index = stack.lastIndex(of: previous) {
            stack.removeSubrange((index + 1)...)
        } else {
            navigate(to: previous)
        }
    }
}
