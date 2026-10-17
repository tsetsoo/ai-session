import Foundation

/// Which todo server holds this device's push token, and what an upload's result means.
///
/// The server keeps a token across launches, so a registration made earlier still covers
/// "needs you" alerts while this launch's upload is in flight or failed for a temporary reason
/// (offline, Tailscale not up yet). Treating those as local-only would alert twice: locally and
/// by push. Only a definite answer (no push support, rejected request) forgets the server.
public struct PushRegistrationState: Equatable, Sendable {
    /// Hub URL the token was last registered with (persist this).
    public private(set) var registeredHub: String?
    /// The last upload failed for a temporary reason: try again when the app becomes active.
    public private(set) var needsRetry = false
    private var generation = 0

    public enum UploadOutcome: Equatable, Sendable {
        case apply(PushState)
        /// A newer upload (or toggle change) superseded this one.
        case ignore
        /// Notifications were switched off while this registration was in flight: delete it again.
        case unregisterAgain
    }

    public init(registeredHub: String? = nil) {
        self.registeredHub = registeredHub
    }

    public func launchState(enabled: Bool, hub: String) -> PushState {
        guard enabled else { return .off }
        return registeredHub == hub ? .registered : .localOnly("Registering for push…")
    }

    /// Returns the token to pass to `finishUpload`.
    public mutating func beginUpload() -> Int {
        generation += 1
        return generation
    }

    /// Notifications switched off: forget the server, supersede uploads in flight.
    public mutating func disable() {
        generation += 1
        registeredHub = nil
        needsRetry = false
    }

    public mutating func finishUpload(_ upload: Int, hub: String, error: TodoHubError?, enabled: Bool) -> UploadOutcome {
        guard upload == generation else {
            return enabled ? .ignore : (error == nil ? .unregisterAgain : .ignore)
        }
        guard let error else {
            registeredHub = hub
            needsRetry = false
            return .apply(.registered)
        }
        switch error {
        case .unreachable, .server:
            needsRetry = true
            return .apply(registeredHub == hub ? .registered : .localOnly(error.userMessage))
        case .unsupported:
            registeredHub = nil
            needsRetry = false
            return .apply(.localOnly("The todo server has no push support yet"))
        default:
            registeredHub = nil
            needsRetry = false
            return .apply(.localOnly(error.userMessage))
        }
    }
}

/// The conversation on screen, as the server should see it: nothing while the app is in the
/// background, the same conversation again when it comes back.
public struct PresenceTracker: Equatable, Sendable {
    public enum Report: Equatable, Sendable {
        case none
        /// Tell the server this todo (or nothing) is on screen.
        case report(String?)
    }

    private var requested: String?
    private var active = true

    public init() {}

    public var visibleTodoId: String? { active ? requested : nil }

    public mutating func request(_ todoId: String?) -> Report {
        let before = visibleTodoId
        requested = todoId
        return visibleTodoId == before ? .none : .report(visibleTodoId)
    }

    public mutating func enterBackground() -> Report {
        let before = visibleTodoId
        active = false
        return before == nil ? .none : .report(nil)
    }

    public mutating func becomeActive() -> Report {
        let before = visibleTodoId
        active = true
        return visibleTodoId == before ? .none : .report(visibleTodoId)
    }
}
