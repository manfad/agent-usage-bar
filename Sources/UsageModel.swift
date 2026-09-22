import Foundation

/// What a session row measures. A window is a percentage of an allowance that refills; credits
/// are an amount already spent, with or without a cap to spend it against.
enum SessionKind: Equatable, Sendable {
    case window
    case credits(used: Double, cap: Double?, unit: String)
}

struct UsageSession: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var resetText: String
    /// For `.window` this is the window's utilisation. For `.credits` it is `used / cap`, so the
    /// menu-bar label can still read a peak across every kind of session; without a cap it is 0.
    var usedPercent: Double
    var kind: SessionKind = .window
}

extension UsageSession {
    /// How much of the bar to fill: what is left. `nil` when there is no cap to measure against,
    /// which draws the track with no fill at all.
    var remainingFraction: Double? {
        switch kind {
        case .window:
            return remainingPercent(used: usedPercent) / 100
        case let .credits(used, cap, _):
            guard let cap, cap > 0 else { return nil }
            return min(max((cap - used) / cap, 0), 1)
        }
    }

    /// The figure beside the bar: what is still available.
    func figureText(locale: Locale = .current) -> String {
        switch kind {
        case .window:
            return formatUsedPercent(remainingPercent(used: usedPercent))
        case let .credits(used, cap, unit):
            guard let cap, cap > 0 else {
                return formatAmount(used, unit: unit, locale: locale)
            }
            return formatAmount(max(cap - used, 0), unit: unit, locale: locale)
        }
    }

    /// The muted line under the bar: the reset for a window, what was spent for credits.
    func captionText(locale: Locale = .current) -> String {
        switch kind {
        case .window:
            return resetText
        case let .credits(used, cap, unit):
            let spent: String
            if let cap, cap > 0 {
                spent = "used \(formatAmount(used, unit: unit, locale: locale))"
                    + " of \(formatAmount(cap, unit: unit, locale: locale))"
            } else {
                spent = "used this period"
            }
            guard !resetText.isEmpty else { return spent }
            return "\(spent) · \(resetText)"
        }
    }
}

struct UsageAgent: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var sessions: [UsageSession]
    var unavailableReason: String?
}

protocol AgentSource: Sendable {
    var id: String { get }
    func load() async -> UsageAgent
}

enum AgentRegistry {
    /// Built-ins are held as instances, not rebuilt per refresh: each one caches its last good
    /// snapshot so a flaky network does not blank the menu.
    private static let builtIns: [any AgentSource] = [
        GrokAgentSource(),
        ClaudeAgentSource()
    ]

    /// The built-ins plus whatever provider folders are on disk right now, so a folder dropped
    /// in while the app runs shows up on the next refresh. A plugin that claims a built-in id
    /// replaces it, in the built-in's place.
    static func sources() -> [any AgentSource] {
        var ordered: [String] = []
        var byID: [String: any AgentSource] = [:]
        for source in builtIns where byID[source.id] == nil {
            ordered.append(source.id)
            byID[source.id] = source
        }
        for plugin in ProviderCatalog.scan() {
            if byID[plugin.id] == nil {
                ordered.append(plugin.id)
            }
            byID[plugin.id] = plugin
        }
        return ordered.compactMap { byID[$0] }
    }

    /// Ids we can name without touching the disk: the built-ins plus whatever the last scan saw.
    /// The settings list re-reads this on every redraw, which is no reason to re-stat a folder.
    static func knownIDs() -> [String] {
        var ids = builtIns.map(\.id)
        for id in ProviderCatalog.names.keys.sorted() where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }
}

func formatUsedPercent(_ usedPercent: Double) -> String {
    let value = Int(usedPercent.rounded())
    return "\(value)%"
}

/// Currency-ish units lead the number and keep two decimals; anything else trails it as a plain
/// grouped count, so `$37.60` and `1,240 tokens` both read naturally.
private let leadingUnits: Set<String> = ["$", "€", "£"]

func formatAmount(_ value: Double, unit: String, locale: Locale = .current) -> String {
    let symbol = unit.trimmingCharacters(in: .whitespacesAndNewlines)
    if leadingUnits.contains(symbol) {
        return symbol + groupedNumber(value, fractionDigits: 2, locale: locale)
    }
    let number = groupedNumber(value.rounded(), fractionDigits: 0, locale: locale)
    return symbol.isEmpty ? number : "\(number) \(symbol)"
}

private func groupedNumber(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    return formatter.string(from: NSNumber(value: value))
        ?? String(format: "%.\(fractionDigits)f", value)
}

enum SampleUsage {
    static let agents: [UsageAgent] = [
        UsageAgent(
            id: "grok",
            name: "Grok",
            sessions: [
                UsageSession(
                    id: "weekly",
                    name: "Weekly limit",
                    resetText: "Resets Sep 26",
                    usedPercent: 16
                )
            ],
            unavailableReason: nil
        ),
        UsageAgent(
            id: "chatgpt",
            name: "ChatGPT",
            sessions: [
                UsageSession(
                    id: "5h",
                    name: "5h limit",
                    resetText: "Resets in 2h 10m",
                    usedPercent: 42
                ),
                UsageSession(
                    id: "weekly",
                    name: "Weekly limit",
                    resetText: "Resets Sep 24",
                    usedPercent: 13
                )
            ],
            unavailableReason: nil
        ),
        UsageAgent(
            id: "claude",
            name: "Claude",
            sessions: [
                UsageSession(
                    id: "5h",
                    name: "5h limit",
                    resetText: "Resets in 45m",
                    usedPercent: 71
                ),
                UsageSession(
                    id: "weekly",
                    name: "Weekly limit",
                    resetText: "Resets Sep 28",
                    usedPercent: 93
                ),
                UsageSession(
                    id: "fable",
                    name: "Fable",
                    resetText: "Resets Sep 28",
                    usedPercent: 8
                )
            ],
            unavailableReason: nil
        ),
        // Both kinds on one agent: a spend-down balance and a plain rate window.
        UsageAgent(
            id: "openai-api",
            name: "OpenAI API",
            sessions: [
                UsageSession(
                    id: "credits",
                    name: "API credits",
                    resetText: "Resets Oct 1",
                    usedPercent: 24.8,
                    kind: .credits(used: 12.4, cap: 50, unit: "$")
                ),
                UsageSession(
                    id: "tokens",
                    name: "Spend today",
                    resetText: "",
                    usedPercent: 0,
                    kind: .credits(used: 3.28, cap: nil, unit: "$")
                ),
                UsageSession(
                    id: "5h",
                    name: "Rate limit",
                    resetText: "Resets in 1h 5m",
                    usedPercent: 31
                )
            ],
            unavailableReason: nil
        )
    ]
}

enum StatusText {
    static func label(for agents: [UsageAgent]) -> String {
        guard let peak = agents.flatMap(\.sessions).map(\.usedPercent).max() else {
            return "—"
        }
        return formatUsedPercent(peak)
    }
}
