import Foundation

/// Maps `GET /api/oauth/usage` onto the session rows the menu renders: the 5-hour window, the
/// weekly window, and one row per model-scoped weekly limit.
func parseClaudeUsageSessions(
    _ data: Data,
    now: Date = Date(),
    timeZone: TimeZone = .current,
    locale: Locale = .current
) throws -> [UsageSession] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ClaudeLoadError.badPayload
    }

    var sessions: [UsageSession] = []
    var seen = Set<String>()
    func append(_ session: UsageSession) {
        guard seen.insert(session.id).inserted else { return }
        sessions.append(session)
    }

    if let window = root["five_hour"] as? [String: Any],
       let percent = jsonDouble(window["utilization"]), percent.isFinite {
        append(UsageSession(
            id: "five_hour",
            name: "5h limit",
            resetText: fiveHourReset(window["resets_at"], now: now),
            usedPercent: percent
        ))
    }

    if let window = root["seven_day"] as? [String: Any],
       let percent = jsonDouble(window["utilization"]), percent.isFinite {
        append(UsageSession(
            id: "seven_day",
            name: "Weekly limit",
            resetText: weeklyReset(window["resets_at"], now: now, timeZone: timeZone, locale: locale),
            usedPercent: percent
        ))
    }

    for entry in root["limits"] as? [Any] ?? [] {
        guard let limit = entry as? [String: Any],
              let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any],
              let name = model["display_name"] as? String,
              !name.isEmpty,
              isWeeklyScoped(limit),
              let percent = jsonDouble(limit["percent"]), percent.isFinite else {
            continue
        }
        append(UsageSession(
            id: modelSessionID(name),
            name: name,
            resetText: weeklyReset(limit["resets_at"], now: now, timeZone: timeZone, locale: locale),
            usedPercent: percent
        ))
    }

    // Legacy per-model windows, only for models `limits` did not already describe.
    for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
        guard let window = root[key] as? [String: Any],
              let percent = jsonDouble(window["utilization"]), percent.isFinite else {
            continue
        }
        append(UsageSession(
            id: modelSessionID(name),
            name: name,
            resetText: weeklyReset(window["resets_at"], now: now, timeZone: timeZone, locale: locale),
            usedPercent: percent
        ))
    }

    guard !sessions.isEmpty else { throw ClaudeLoadError.badPayload }
    return sessions
}

private func modelSessionID(_ displayName: String) -> String {
    "model_\(displayName.lowercased())"
}

private func isWeeklyScoped(_ limit: [String: Any]) -> Bool {
    if let group = limit["group"] as? String, group == "weekly" { return true }
    if let kind = limit["kind"] as? String, kind.contains("weekly") { return true }
    return false
}

/// A window with no usable timestamp still shows its percentage, just with no reset line.
private func weeklyReset(_ value: Any?, now: Date, timeZone: TimeZone, locale: Locale) -> String {
    guard let iso = value as? String,
          let text = ResetText.weekly(isoEnd: iso, now: now, timeZone: timeZone, locale: locale) else {
        return ""
    }
    return text
}

private func fiveHourReset(_ value: Any?, now: Date) -> String {
    guard let iso = value as? String,
          let text = ResetText.fiveHour(isoEnd: iso, now: now) else {
        return ""
    }
    return text
}

final class ClaudeAgentSource: AgentSource, @unchecked Sendable {
    let id = "claude"
    private let lock = NSLock()
    private var snapshot: UsageAgent?

    func load() async -> UsageAgent {
        do {
            let credentials = try ClaudeAuth.credentials()
            let sessions = try await fetchSessions(accessToken: credentials.accessToken)
            let agent = UsageAgent(id: id, name: "Claude", sessions: sessions, unavailableReason: nil)
            store(agent)
            return agent
        } catch let error as ClaudeLoadError {
            return failure(error)
        } catch {
            return failure(.network)
        }
    }

    private func fetchSessions(accessToken: String) async throws -> [UsageSession] {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ClaudeLoadError.network
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeLoadError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeLoadError.network
        }
        if http.statusCode == 401 {
            throw ClaudeLoadError.signInExpired
        }
        // 429 is a rate limit on the usage endpoint itself, not the user's plan — hold the
        // last good snapshot rather than blanking the menu.
        if http.statusCode != 200 {
            throw ClaudeLoadError.network
        }
        return try parseClaudeUsageSessions(data)
    }

    private func failure(_ error: ClaudeLoadError) -> UsageAgent {
        switch error {
        case .network:
            if let cached = cached() { return cached }
            return failed("Couldn't reach Claude")
        case .notSignedIn:
            clear()
            return failed("Not signed in")
        case .signInExpired:
            clear()
            return failed("Sign-in expired — run claude to refresh")
        case .unreadableSignIn:
            clear()
            return failed("Couldn't read sign-in")
        case .badPayload:
            clear()
            return failed("Couldn't read usage")
        }
    }

    private func failed(_ reason: String) -> UsageAgent {
        UsageAgent(id: id, name: "Claude", sessions: [], unavailableReason: reason)
    }

    private func store(_ agent: UsageAgent) {
        lock.lock()
        snapshot = agent
        lock.unlock()
    }

    private func cached() -> UsageAgent? {
        lock.lock()
        let value = snapshot
        lock.unlock()
        return value
    }

    private func clear() {
        lock.lock()
        snapshot = nil
        lock.unlock()
    }
}
