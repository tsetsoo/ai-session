import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why consumers should re-fetch.
public enum TodoHubEvent: Equatable, Sendable {
    /// The server changed something.
    case changed
    /// The socket dropped and is reconnecting: changes may have been missed. The next snapshot
    /// is a fresh baseline (no "turned waiting" alerts for what happened meanwhile).
    case reconnected
}

/// Listens on the hub's `/api/ws` and yields one event per server-side change. The server
/// sends a bare `refresh` text frame on every mutation; consumers re-fetch what they show.
///
/// Reconnects with exponential backoff (1s → 30s). Independently reconciles every 15s:
/// a half-open socket or a missed frame must not freeze conversation status indefinitely.
public enum TodoHubEvents {
    public static func refreshes(
        baseURL: URL,
        token: String?,
        session: URLSession = .shared,
        reconciliationInterval: Duration = .seconds(15)
    ) -> AsyncStream<TodoHubEvent> {
        precondition(reconciliationInterval > .zero)
        return AsyncStream { continuation in
            let task = Task {
                var delay: UInt64 = 1
                while !Task.isCancelled {
                    guard let url = webSocketURL(baseURL: baseURL, token: token) else { return }
                    let socket = session.webSocketTask(with: url)
                    socket.resume()
                    await withTaskCancellationHandler {
                        do {
                            while !Task.isCancelled {
                                _ = try await socket.receive()
                                delay = 1
                                continuation.yield(.changed)
                            }
                        } catch {
                            // The retry below refreshes after the connection was lost.
                        }
                    } onCancel: {
                        socket.cancel(with: .goingAway, reason: nil)
                    }
                    socket.cancel(with: .goingAway, reason: nil)
                    guard !Task.isCancelled else { break }
                    // A reconnect may have missed changes: ask consumers to refresh once more.
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    delay = min(delay * 2, 30)
                    continuation.yield(.reconnected)
                }
            }
            let reconcile = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: reconciliationInterval) } catch { return }
                    guard !Task.isCancelled else { return }
                    continuation.yield(.changed)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                reconcile.cancel()
            }
        }
    }

    /// `http(s)://host:port` → `ws(s)://host:port/api/ws?token=…`. The token goes in the
    /// query because `URLSessionWebSocketTask` handshakes are simplest without custom headers;
    /// the server accepts both and never logs query strings.
    public static func webSocketURL(baseURL: URL, token: String?) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = components.path + "/api/ws"
        if let token, !token.isEmpty {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        return components.url
    }
}
