import XCTest
@testable import AgentUsage

final class SettingsTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    /// Every case gets its own suite so nothing here can reach the user's real preferences.
    private func makeDefaults() -> UserDefaults {
        let name = "agent-usage.tests.\(UUID().uuidString)"
        suiteNames.append(name)
        guard let defaults = UserDefaults(suiteName: name) else {
            XCTFail("could not open an isolated defaults suite")
            return UserDefaults.standard
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func preferences(
        order: [String] = [],
        hidden: Set<String> = [],
        defaults: UserDefaults? = nil
    ) -> AgentPreferences {
        let preferences = AgentPreferences(defaults: defaults ?? makeDefaults())
        preferences.order = order
        preferences.hidden = hidden
        return preferences
    }

    private func agent(_ id: String) -> UsageAgent {
        UsageAgent(id: id, name: AgentPreferences.displayName(for: id), sessions: [], unavailableReason: nil)
    }

    func testArrangedRespectsStoredOrder() {
        let preferences = preferences(order: ["claude", "grok"])
        let arranged = preferences.arranged([agent("grok"), agent("claude")])
        XCTAssertEqual(arranged.map(\.id), ["claude", "grok"])
    }

    func testArrangedDropsHiddenAgents() {
        let preferences = preferences(order: ["grok", "claude"], hidden: ["grok"])
        let arranged = preferences.arranged([agent("grok"), agent("claude")])
        XCTAssertEqual(arranged.map(\.id), ["claude"])
    }

    func testArrangedAppendsUnknownIDsInIncomingOrder() {
        let preferences = preferences(order: ["claude"])
        let arranged = preferences.arranged([agent("grok"), agent("claude"), agent("chatgpt")])
        XCTAssertEqual(arranged.map(\.id), ["claude", "grok", "chatgpt"])
    }

    func testArrangedIsStableAcrossRepeatedCalls() {
        let preferences = preferences(order: ["claude"])
        let incoming = [agent("grok"), agent("claude"), agent("chatgpt"), agent("gemini")]
        let first = preferences.arranged(incoming).map(\.id)
        XCTAssertEqual(first, ["claude", "grok", "chatgpt", "gemini"])
        XCTAssertEqual(preferences.arranged(incoming).map(\.id), first)
        XCTAssertEqual(preferences.arranged(incoming).map(\.id), first)
    }

    func testArrangedWithEmptyOrderKeepsIncomingOrder() {
        let preferences = preferences()
        let arranged = preferences.arranged([agent("claude"), agent("grok")])
        XCTAssertEqual(arranged.map(\.id), ["claude", "grok"])
    }

    func testArrangedIgnoresOrderEntriesWithNoMatchingAgent() {
        let preferences = preferences(order: ["gemini", "claude", "grok"])
        let arranged = preferences.arranged([agent("grok"), agent("claude")])
        XCTAssertEqual(arranged.map(\.id), ["claude", "grok"])
    }

    func testMoveRewritesOrder() {
        let preferences = preferences(order: ["grok", "claude", "chatgpt"])
        preferences.move(
            fromOffsets: IndexSet(integer: 2),
            toOffset: 0,
            within: ["grok", "claude", "chatgpt"]
        )
        XCTAssertEqual(preferences.order, ["chatgpt", "grok", "claude"])
        XCTAssertEqual(
            preferences.arranged([agent("grok"), agent("claude"), agent("chatgpt")]).map(\.id),
            ["chatgpt", "grok", "claude"]
        )
    }

    func testMoveKeepsKnownIDsThatWereNotOnScreen() {
        let preferences = preferences(order: ["grok", "claude", "gemini"])
        preferences.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, within: ["grok", "claude"])
        XCTAssertEqual(preferences.order, ["claude", "grok", "gemini"])
    }

    func testSetHiddenTogglesBothWays() {
        let preferences = preferences(order: ["grok", "claude"])
        preferences.setHidden("grok", true)
        XCTAssertTrue(preferences.isHidden("grok"))
        XCTAssertEqual(preferences.arranged([agent("grok"), agent("claude")]).map(\.id), ["claude"])
        preferences.setHidden("grok", false)
        XCTAssertFalse(preferences.isHidden("grok"))
        XCTAssertEqual(preferences.arranged([agent("grok"), agent("claude")]).map(\.id), ["grok", "claude"])
    }

    func testOrderAndHiddenSurviveANewInstanceOnTheSameDefaults() {
        let defaults = makeDefaults()
        let first = preferences(order: ["claude", "grok"], hidden: ["grok"], defaults: defaults)
        XCTAssertEqual(first.order, ["claude", "grok"])

        let second = AgentPreferences(defaults: defaults)
        XCTAssertEqual(second.order.prefix(2).map { $0 }, ["claude", "grok"])
        XCTAssertEqual(second.hidden, ["grok"])
    }

    func testDisplayNames() {
        XCTAssertEqual(AgentPreferences.displayName(for: "grok"), "Grok")
        XCTAssertEqual(AgentPreferences.displayName(for: "chatgpt"), "ChatGPT")
        XCTAssertEqual(AgentPreferences.displayName(for: "claude"), "Claude")
        XCTAssertEqual(AgentPreferences.displayName(for: "gemini"), "Gemini")
    }
}
