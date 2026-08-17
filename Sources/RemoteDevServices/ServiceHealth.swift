public enum ServiceHealth: Equatable, Sendable {
    case stopped
    case starting
    case healthy
    case unhealthy(String)
}
