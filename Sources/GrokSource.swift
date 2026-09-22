import Foundation

final class GrokAgentSource: AgentSource, @unchecked Sendable {
    let id = "grok"
    private let lock = NSLock()
    private var snapshot: UsageAgent?

    func load() async -> UsageAgent {
        do {
            let session = try await fetchSession(forceRefresh: false)
            let agent = UsageAgent(id: id, name: "Grok", sessions: [session], unavailableReason: nil)
            store(agent)
            return agent
        } catch let error as GrokLoadError {
            return failure(error)
        } catch {
            return failure(.network)
        }
    }

    private func fetchSession(forceRefresh: Bool) async throws -> UsageSession {
        let token = try await GrokAuth.accessToken(forceRefresh: forceRefresh)
        do {
            return try await fetchBilling(accessToken: token)
        } catch GrokLoadError.signInExpired where !forceRefresh {
            return try await fetchSession(forceRefresh: true)
        }
    }

    private func fetchBilling(accessToken: String) async throws -> UsageSession {
        guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits") else {
            throw GrokLoadError.network
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("xai-grok-cli/0.2.118", forHTTPHeaderField: "User-Agent")
        request.setValue("0.2.118", forHTTPHeaderField: "x-grok-client-version")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GrokLoadError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw GrokLoadError.network
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw GrokLoadError.signInExpired
        }
        if http.statusCode != 200 {
            throw GrokLoadError.network
        }
        return try parseBillingSession(data)
    }

    private func failure(_ error: GrokLoadError) -> UsageAgent {
        switch error {
        case .network:
            if let cached = cached() { return cached }
            return failed("Couldn't reach Grok")
        case .notSignedIn:
            clear()
            return failed("Not signed in")
        case .signInExpired:
            clear()
            return failed("Sign-in expired")
        case .unreadableSignIn:
            clear()
            return failed("Couldn't read sign-in")
        case .badPayload:
            clear()
            return failed("Couldn't read usage")
        }
    }

    private func failed(_ reason: String) -> UsageAgent {
        UsageAgent(id: id, name: "Grok", sessions: [], unavailableReason: reason)
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
