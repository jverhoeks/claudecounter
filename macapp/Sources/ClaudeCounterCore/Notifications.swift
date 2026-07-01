import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// A user-facing alert derived from a session crossing a warning
/// threshold. `condition` is the debounce dimension — one notification per
/// (session, condition) per active streak.
public struct SessionNotification: Equatable, Sendable {
    public let sessionID: String
    public let condition: String   // "context" | "cache"
    public let title: String
    public let body: String

    public init(sessionID: String, condition: String, title: String, body: String) {
        self.sessionID = sessionID
        self.condition = condition
        self.title = title
        self.body = body
    }
}

/// Pure debounce/crossing computation, factored out so it is unit-testable
/// without touching `UNUserNotificationCenter`.
///
/// - `active`: current active sessions (from `SessionTracker.snapshot`).
/// - `alreadyNotified`: keys (`"<sessionID>|<condition>"`) fired earlier.
///
/// Returns the notifications to post now and the next `alreadyNotified`
/// set. Keys for sessions no longer active are dropped, so a condition can
/// re-arm after a session goes idle and later returns. Only `.context` and
/// `.cache` notify; `.turns` is in-app only.
public func newlyTriggered(
    active: [SessionStat],
    alreadyNotified: Set<String>
) -> (toPost: [SessionNotification], nextNotified: Set<String>) {

    let activeIDs = Set(active.map { $0.sessionID })

    // Carry forward only keys whose session is still active — that's what
    // suppresses a re-fire while the session stays up, and re-arms once it
    // leaves the active set.
    var next = alreadyNotified.filter { key in
        guard let sid = key.split(separator: "|", maxSplits: 1).first else { return false }
        return activeIDs.contains(String(sid))
    }

    var post: [SessionNotification] = []
    for s in active {
        let short = shortProjectName(s.project)
        if s.warnings.contains(.context) {
            let key = "\(s.sessionID)|context"
            if !next.contains(key) {
                let pct = Int((s.contextPct * 100).rounded())
                post.append(SessionNotification(
                    sessionID: s.sessionID, condition: "context",
                    title: "Context nearly full",
                    body: "\(short) · \(pct)% of window"))
                next.insert(key)
            }
        }
        if s.warnings.contains(.cache) {
            let key = "\(s.sessionID)|cache"
            if !next.contains(key) {
                post.append(SessionNotification(
                    sessionID: s.sessionID, condition: "cache",
                    title: "High cache-creation spend",
                    body: "\(short) · \(String(format: "$%.2f", s.cacheCreateCostUSD)) creating cache"))
                next.insert(key)
            }
        }
    }
    return (post, next)
}

/// Trim an encoded project key (`-Users-me-src-foo`) down to a readable
/// tail. Mirrors the popover's `shortProject` so notification text matches
/// the UI. Kept here (not private to the view) so the pure notification
/// layer can format bodies without importing SwiftUI.
public func shortProjectName(_ encoded: String) -> String {
    if encoded.isEmpty { return "(unknown)" }
    let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
    let parts = trimmed.split(separator: "-")
    if parts.count <= 4 { return trimmed }
    return parts.dropFirst(4).joined(separator: "-")
}

// MARK: - Notifier seam

/// Delivers session alerts to the OS. Injected into `AppState` so tests
/// use a spy and the production app wires the real `UNUserNotificationCenter`.
public protocol SessionNotifier: Sendable {
    /// Ask the user for notification permission (once, at launch).
    func requestAuthorization()
    /// Post a single alert. No-op if not authorized.
    func post(_ notification: SessionNotification)
}

/// Default no-op notifier. `AppState` uses this unless a real one is
/// injected, so the unit-test runner never touches `UNUserNotificationCenter`
/// (which traps outside a bundled app).
public struct NullSessionNotifier: SessionNotifier {
    public init() {}
    public func requestAuthorization() {}
    public func post(_ notification: SessionNotification) {}
}

#if canImport(UserNotifications)
/// Production notifier backed by `UNUserNotificationCenter`. Wired in the
/// menu-bar app target, never in tests.
public final class UserNotificationsNotifier: SessionNotifier, @unchecked Sendable {
    public init() {}

    public func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in
            // Denied / not-determined is fine — `post` is a no-op then and
            // the in-app warnings + red menu-bar capsule still function.
        }
    }

    public func post(_ notification: SessionNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        // Immediate, non-repeating delivery. Identifier is
        // session+condition so a re-post (should the debounce ever allow
        // one) coalesces rather than stacking duplicates.
        let request = UNNotificationRequest(
            identifier: "\(notification.sessionID)|\(notification.condition)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
#endif
