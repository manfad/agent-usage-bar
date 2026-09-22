import Foundation

/// What a session row measures. A window is a percentage of an allowance that refills; credits
/// are an amount already spent, with or without a cap to spend it against; a balance is a prepaid
/// amount still there, with nothing to measure it against — API billing with no cap and no reset.
enum SessionKind: Equatable, Sendable {
    case window
    case credits(used: Double, cap: Double?, unit: String)
    case balance(remaining: Double, unit: String)
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
        case .balance:
            // A prepaid balance has no allowance behind it, so the track stays empty and the
            // figure carries the whole story.
            return nil
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
        case let .balance(remaining, unit):
            return formatAmount(remaining, unit: unit, locale: locale)
        }
    }

    /// The muted line under the bar: the reset for a window, the cap (or spend hint) for credits,
    /// and for a balance just what the figure is, since nothing else is known about it.
    func captionText(locale: Locale = .current) -> String {
        switch kind {
        case .window:
            return resetText
        case let .credits(_, cap, unit):
            let spent: String
            if let cap, cap > 0 {
                spent = "of \(formatAmount(cap, unit: unit, locale: locale))"
            } else {
                spent = "used this period"
            }
            guard !resetText.isEmpty else { return spent }
            return "\(spent) · \(resetText)"
        case .balance:
            guard !resetText.isEmpty else { return "balance" }
            return "balance · \(resetText)"
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

/// A currency symbol leads the number; an ISO code trails it. Either way the amount keeps two
/// decimals, dropped when it is whole, so a top-up reads `$20` and a balance reads `¥21.47`.
/// Anything else trails the number as a plain grouped count: `1,240 tokens`.
private let leadingUnits: Set<String> = ["$", "€", "£", "¥", "₩", "₹"]

/// ISO 4217 codes a provider may send in place of a symbol. A three-letter unit outside this list
/// is a count of something, not money, so `1,240 GPU` must not become `1,240.00 GPU`.
private let trailingCurrencyCodes: Set<String> = [
    "AED", "ARS", "AUD", "BRL", "CAD", "CHF", "CLP", "CNH", "CNY", "COP", "CZK", "DKK", "EGP",
    "EUR", "GBP", "HKD", "HUF", "IDR", "ILS", "INR", "JPY", "KRW", "MXN", "MYR", "NGN", "NOK",
    "NZD", "PHP", "PLN", "RON", "RUB", "SAR", "SEK", "SGD", "THB", "TRY", "TWD", "UAH", "USD",
    "VND", "ZAR"
]

func formatAmount(_ value: Double, unit: String, locale: Locale = .current) -> String {
    let symbol = unit.trimmingCharacters(in: .whitespacesAndNewlines)
    if leadingUnits.contains(symbol) {
        return symbol + currencyNumber(value, locale: locale)
    }
    if trailingCurrencyCodes.contains(symbol.uppercased()) {
        return "\(currencyNumber(value, locale: locale)) \(symbol)"
    }
    let number = groupedNumber(value.rounded(), fractionDigits: 0, locale: locale)
    return symbol.isEmpty ? number : "\(number) \(symbol)"
}

/// Two decimals, or none when the amount rounds to something whole: a `$20` cap should not be
/// padded out to `$20.00`, and `¥21.47` must keep its cents.
private func currencyNumber(_ value: Double, locale: Locale) -> String {
    let rounded = (value * 100).rounded() / 100
    let digits = rounded == rounded.rounded() ? 0 : 2
    return groupedNumber(rounded, fractionDigits: digits, locale: locale)
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
