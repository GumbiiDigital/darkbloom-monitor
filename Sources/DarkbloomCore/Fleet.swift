import Foundation

public struct FleetRosterEntry: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var serialNumber: String

    public var id: String { serialNumber }

    public init(name: String, serialNumber: String) {
        self.name = name
        self.serialNumber = serialNumber
    }
}

public enum FleetRosterDefaults {
    public static let entries = [
        FleetRosterEntry(name: "WV0", serialNumber: "WV0NCDC2TX"),
        FleetRosterEntry(name: "G2YF", serialNumber: "G2YFW5NXXQ"),
        FleetRosterEntry(name: "HDCF", serialNumber: "HDCFM44C69"),
        FleetRosterEntry(name: "KDQ", serialNumber: "KDQHYG765D"),
        FleetRosterEntry(name: "DRXY", serialNumber: "DRXYPT2MKX"),
        FleetRosterEntry(name: "M5", serialNumber: "LQW9G9WRDC"),
    ]
}

public enum FleetRosterStore {
    private static let rosterKey = "darkbloom.monitor.fleet.roster.v1"
    private static let identityKey = "darkbloom.monitor.fleet.identity-history.v1"

    public static func loadRoster(defaults: UserDefaults = .standard) -> [FleetRosterEntry] {
        guard let data = defaults.data(forKey: rosterKey),
              let roster = try? JSONDecoder().decode([FleetRosterEntry].self, from: data),
              !roster.isEmpty
        else { return FleetRosterDefaults.entries }
        return roster
    }

    public static func saveRoster(_ roster: [FleetRosterEntry], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(roster) else { return }
        defaults.set(data, forKey: rosterKey)
    }

    public static func loadIdentityHistory(defaults: UserDefaults = .standard) -> FleetIdentityHistory {
        guard let data = defaults.data(forKey: identityKey),
              let history = try? JSONDecoder().decode(FleetIdentityHistory.self, from: data)
        else { return FleetIdentityHistory() }
        return history
    }

    public static func saveIdentityHistory(_ history: FleetIdentityHistory, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: identityKey)
    }
}

public struct FleetIdentityHistory: Codable, Equatable, Sendable {
    public var providerToSerial: [String: String]

    public init(providerToSerial: [String: String] = [:]) {
        self.providerToSerial = providerToSerial
    }

    public mutating func record(
        _ providers: [CoordinatorAPI.AttestedProvider],
        roster: [FleetRosterEntry]
    ) {
        let serials = Set(roster.map(\.serialNumber))
        for provider in providers where serials.contains(provider.serialNumber) {
            providerToSerial[provider.providerID] = provider.serialNumber
        }
    }
}

public enum FleetPeriod: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case hour
    case day
    case week
    case lifetime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hour: return "1h"
        case .day: return "24h"
        case .week: return "7d"
        case .lifetime: return "Lifetime"
        }
    }

    fileprivate var interval: TimeInterval? {
        switch self {
        case .hour: return 3_600
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .lifetime: return nil
        }
    }
}

public struct FleetMetrics: Equatable, Sendable {
    public var jobs: Int
    public var inputTokens: UInt64
    public var outputTokens: UInt64
    public var earningsMicroUSD: Int64
    public var lastActivity: Date?

    public var totalTokens: UInt64 { inputTokens + outputTokens }

    public init(
        jobs: Int = 0,
        inputTokens: UInt64 = 0,
        outputTokens: UInt64 = 0,
        earningsMicroUSD: Int64 = 0,
        lastActivity: Date? = nil
    ) {
        self.jobs = jobs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.earningsMicroUSD = earningsMicroUSD
        self.lastActivity = lastActivity
    }

    fileprivate mutating func add(_ earning: CoordinatorAPI.Earning) {
        jobs += 1
        inputTokens += UInt64(max(0, earning.promptTokens))
        outputTokens += UInt64(max(0, earning.completionTokens))
        earningsMicroUSD += earning.amountMicroUSD
        if lastActivity == nil || earning.createdAt > lastActivity! {
            lastActivity = earning.createdAt
        }
    }

    fileprivate static func sum(_ metrics: [FleetMetrics]) -> FleetMetrics {
        metrics.reduce(into: FleetMetrics()) { result, value in
            result.jobs += value.jobs
            result.inputTokens += value.inputTokens
            result.outputTokens += value.outputTokens
            result.earningsMicroUSD += value.earningsMicroUSD
            if result.lastActivity == nil || (value.lastActivity ?? .distantPast) > (result.lastActivity ?? .distantPast) {
                result.lastActivity = value.lastActivity
            }
        }
    }
}

public enum FleetRowStatus: Equatable, Sendable {
    case online
    case offline
    case neverSeen

    public var title: String {
        switch self {
        case .online: return "Online"
        case .offline: return "Offline"
        case .neverSeen: return "Not seen"
        }
    }
}

public struct FleetRow: Identifiable, Equatable, Sendable {
    public var roster: FleetRosterEntry
    public var live: CoordinatorAPI.AttestedProvider?
    public var metrics: FleetMetrics
    public var status: FleetRowStatus

    public var id: String { roster.id }

    public var modelsText: String {
        guard let models = live?.models, !models.isEmpty else { return "No model reported" }
        return models.joined(separator: ", ")
    }

    public var trustText: String {
        guard let live else { return "Trust unavailable" }
        return "Trust \(live.trustLevel)"
    }
}

public struct FleetSnapshot: Equatable, Sendable {
    public var period: FleetPeriod
    public var rows: [FleetRow]
    public var totals: FleetMetrics
    public var unattributed: FleetMetrics
    public var historyIsSampled: Bool

    public init(
        period: FleetPeriod,
        rows: [FleetRow],
        totals: FleetMetrics,
        unattributed: FleetMetrics,
        historyIsSampled: Bool
    ) {
        self.period = period
        self.rows = rows
        self.totals = totals
        self.unattributed = unattributed
        self.historyIsSampled = historyIsSampled
    }
}

public enum FleetAnalytics {
    public static func snapshot(
        roster: [FleetRosterEntry],
        connected: [CoordinatorAPI.AttestedProvider],
        earnings: CoordinatorAPI.AccountEarnings,
        identityHistory: FleetIdentityHistory,
        period: FleetPeriod,
        now: Date = Date()
    ) -> (snapshot: FleetSnapshot, identityHistory: FleetIdentityHistory) {
        var history = identityHistory
        history.record(connected, roster: roster)

        let rosterBySerial = Dictionary(uniqueKeysWithValues: roster.map { ($0.serialNumber, $0) })
        let liveBySerial = Dictionary(
            connected.compactMap { provider -> (String, CoordinatorAPI.AttestedProvider)? in
                guard rosterBySerial[provider.serialNumber] != nil else { return nil }
                return (provider.serialNumber, provider)
            }, uniquingKeysWith: { first, _ in first })
        let cutoff = period.interval.map { now.addingTimeInterval(-$0) }
        let eligible = earnings.earnings.filter { cutoff == nil || $0.createdAt > cutoff! }

        var metricsBySerial = Dictionary(uniqueKeysWithValues: roster.map { ($0.serialNumber, FleetMetrics()) })
        var unattributed = FleetMetrics()
        for earning in eligible {
            guard let serial = history.providerToSerial[earning.providerID], rosterBySerial[serial] != nil else {
                unattributed.add(earning)
                continue
            }
            metricsBySerial[serial, default: FleetMetrics()].add(earning)
        }

        // The API's lifetime total includes older jobs that may not be present in
        // its bounded recent-history payload. Keep that gap explicit instead of
        // silently assigning it to a machine.
        if period == .lifetime {
            let returned = earnings.earnings.reduce(Int64(0)) { $0 + $1.amountMicroUSD }
            let gap = max(0, earnings.totalMicroUSD - returned)
            unattributed.earningsMicroUSD += gap
        }

        let rows = roster.map { entry in
            let live = liveBySerial[entry.serialNumber]
            let status: FleetRowStatus = if let live {
                ["online", "serving", "earning"].contains(live.status.lowercased()) ? .online : .offline
            } else if history.providerToSerial.values.contains(entry.serialNumber) {
                .offline
            } else {
                .neverSeen
            }
            return FleetRow(
                roster: entry,
                live: live,
                metrics: metricsBySerial[entry.serialNumber] ?? FleetMetrics(),
                status: status
            )
        }
        let totals = FleetMetrics.sum(rows.map(\.metrics) + [unattributed])
        let sampled = earnings.historyLimit.map { earnings.earnings.count >= $0 } ?? false
        return (
            FleetSnapshot(
                period: period,
                rows: rows,
                totals: totals,
                unattributed: unattributed,
                historyIsSampled: sampled
            ),
            history
        )
    }
}
