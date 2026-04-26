import Foundation

/// One UI-facing event for the live tail at the bottom of the popover.
/// Smaller than `UsageEvent` — just what the row needs to render.
public struct LiveEvent: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let project: String
    public let model: String
    public let usd: Double
    public let isSubagent: Bool

    public init(timestamp: Date, project: String, model: String,
                usd: Double, isSubagent: Bool, id: UUID = UUID()) {
        self.id = id
        self.timestamp = timestamp
        self.project = project
        self.model = model
        self.usd = usd
        self.isSubagent = isSubagent
    }

    public static func from(_ ev: UsageEvent, pricing: PricingTable) -> LiveEvent {
        LiveEvent(
            timestamp: ev.timestamp,
            project: ev.project,
            model: ev.model,
            usd: pricing.cost(model: ev.model, usage: ev.usage),
            isSubagent: ev.isSubagent
        )
    }
}

/// Bounded ring buffer of recent events. Newest at the front (index 0).
/// Capacity-50 buffer is plenty for the popover's "Live" section.
public struct LiveEventBuffer: Sendable {
    public private(set) var items: [LiveEvent] = []
    public let capacity: Int

    public init(capacity: Int = 50) {
        self.capacity = capacity
        self.items.reserveCapacity(capacity)
    }

    public mutating func push(_ ev: LiveEvent) {
        items.insert(ev, at: 0)
        if items.count > capacity {
            items.removeLast(items.count - capacity)
        }
    }

    public mutating func clear() {
        items.removeAll(keepingCapacity: true)
    }
}
