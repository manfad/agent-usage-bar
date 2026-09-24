import Foundation

enum GrokLoadError: Error, Equatable {
    case notSignedIn
    case signInExpired
    case unreadableSignIn
    case badPayload
    case network
}

/// Reset copy shared by every agent: short windows count down, distant ones name the day.
enum ResetText {
    private static let day: TimeInterval = 24 * 60 * 60

    /// Tolerates both `2026-09-22T11:30:00.123456-07:00` and the plain second-resolution form.
    static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// `Resets in 3h 20m`, `Resets in 45m`, or `Resets soon` once there is less than a minute
    /// left or the window has already turned over.
    static func countdown(until end: Date, now: Date) -> String {
        let remaining = end.timeIntervalSince(now)
        if remaining < 60 {
            return "Resets soon"
        }
        let minutes = Int(remaining / 60)
        if minutes < 60 {
            return "Resets in \(minutes)m"
        }
        let hours = minutes / 60
        let trailing = minutes % 60
        if trailing == 0 {
            return "Resets in \(hours)h"
        }
        return "Resets in \(hours)h \(trailing)m"
    }

    /// Weekly and model-scoped weekly windows read as `Resets Sep 23`, except in their last day,
    /// where a countdown is the more useful thing to show. This is also what a plugin's own
    /// period uses, since a provider does not say what sort of window it is describing.
    static func weekly(until end: Date, now: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        if end.timeIntervalSince(now) <= day {
            return countdown(until: end, now: now)
        }
        return "Resets \(shortDate(end, timeZone: timeZone, locale: locale))"
    }

    static func shortDate(_ date: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }
}

func parseBillingSession(_ data: Data) throws -> UsageSession {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let config = root["config"] as? [String: Any] else {
        throw GrokLoadError.badPayload
    }
    // Grok reports the share of the week still available (the Grok app shows the same
    // number as "left"), whereas Claude reports the share consumed. Normalise to used here.
    guard let remaining = jsonDouble(config["creditUsagePercent"]), remaining.isFinite else {
        throw GrokLoadError.badPayload
    }
    let percent = min(max(100 - remaining, 0), 100)
    guard let period = config["currentPeriod"] as? [String: Any],
          let end = period["end"] as? String,
          let resetsAt = ResetText.parseISO8601(end) else {
        throw GrokLoadError.badPayload
    }
    return UsageSession(
        id: "weekly",
        name: "Weekly limit",
        resetsAt: resetsAt,
        usedPercent: percent
    )
}

func jsonDouble(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
        return number.doubleValue
    }
    if let string = value as? String {
        return Double(string)
    }
    return nil
}
