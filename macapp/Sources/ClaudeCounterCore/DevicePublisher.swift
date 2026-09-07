import Foundation

/// PUTs a `DevicePayload` to the Cloudflare Worker. Remembers the last
/// body it successfully sent and skips a send whose body is byte-equal,
/// which is what keeps the app inside KV's daily write quota: spend
/// changes far less than once a minute outside an active session.
///
/// No retry or backoff of its own: the caller runs on a 60 s tick, and
/// a failed send is not remembered, so the next tick retries.
public actor DevicePublisher {

    public enum Outcome: Equatable, Sendable {
        case sent
        case unchanged
        case failed(String)
    }

    public static let timeout: TimeInterval = 10

    private var lastSent: Data?

    public init() {}

    public func publish(_ payload: DevicePayload,
                        to url: URL,
                        token: String,
                        session: URLSessionProtocol) async -> Outcome {
        let body: Data
        do { body = try payload.encoded() } catch { return .failed("encode: \(error)") }
        if body == lastSent { return .unchanged }

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.timeoutInterval = Self.timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        do {
            let (_, resp) = try await session.dataReturning(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failed("non-HTTP response") }
            guard (200..<300).contains(http.statusCode) else { return .failed("HTTP \(http.statusCode)") }
            lastSent = body
            return .sent
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Forget the last body so the next `publish` always sends. Used by
    /// the popover's "Send now" so the user gets a real round-trip.
    public func reset() { lastSent = nil }
}
