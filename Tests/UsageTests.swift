import XCTest
@testable import AgentUsage

final class UsageTests: XCTestCase {
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let enUS = Locale(identifier: "en_US")

    private func at(_ iso: String) -> Date {
        guard let date = ResetText.parseISO8601(iso) else {
            XCTFail("unparseable fixture date \(iso)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    func testParsesBillingFixtureIntoWeeklySession() throws {
        let json = """
        {
          "config": {
            "creditUsagePercent": 13.4,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-09-19T08:21:18.802818+00:00",
              "end": "2026-09-26T08:21:18.802818+00:00"
            },
            "productUsage": [
              { "product": "GrokBuild", "usagePercent": 40 }
            ]
          }
        }
        """
        let session = try parseBillingSession(
            Data(json.utf8),
            now: at("2026-09-22T09:00:00-07:00"),
            timeZone: losAngeles,
            locale: enUS
        )
        XCTAssertEqual(session.name, "Weekly limit")
        XCTAssertEqual(session.usedPercent, 86.6, accuracy: 0.0001)  // API value is percent left
        XCTAssertEqual(session.resetText, "Resets Sep 26")
        XCTAssertEqual(session.id, "weekly")
    }

    func testGrokWeeklyCountsDownInsideTheFinalDay() throws {
        let json = """
        {
          "config": {
            "creditUsagePercent": 88,
            "currentPeriod": {
              "end": "2026-09-22T14:10:00+00:00"
            }
          }
        }
        """
        let session = try parseBillingSession(
            Data(json.utf8),
            now: at("2026-09-22T09:00:00+00:00"),
            timeZone: losAngeles,
            locale: enUS
        )
        XCTAssertEqual(session.resetText, "Resets in 5h 10m")
    }

    func testResetDayIsNotZeroPadded() {
        XCTAssertEqual(
            ResetText.weekly(
                isoEnd: "2026-10-06T08:21:18.802818+00:00",
                now: at("2026-09-22T09:00:00-07:00"),
                timeZone: losAngeles,
                locale: enUS
            ),
            "Resets Oct 6"
        )
    }

    func testCountdownWording() {
        let now = at("2026-09-22T09:00:00+00:00")
        XCTAssertEqual(ResetText.countdown(until: at("2026-09-22T12:20:00+00:00"), now: now), "Resets in 3h 20m")
        XCTAssertEqual(ResetText.countdown(until: at("2026-09-22T12:00:00+00:00"), now: now), "Resets in 3h")
        XCTAssertEqual(ResetText.countdown(until: at("2026-09-22T09:45:00+00:00"), now: now), "Resets in 45m")
        XCTAssertEqual(ResetText.countdown(until: at("2026-09-22T09:00:30+00:00"), now: now), "Resets soon")
        XCTAssertEqual(ResetText.countdown(until: at("2026-09-22T08:00:00+00:00"), now: now), "Resets soon")
    }

    func testWeeklyUsesLocalCalendarDayForTheShortDate() {
        // 2026-09-27T02:00Z is still September 26 in Los Angeles.
        let now = at("2026-09-20T09:00:00+00:00")
        XCTAssertEqual(
            ResetText.weekly(isoEnd: "2026-09-27T02:00:00+00:00", now: now, timeZone: losAngeles, locale: enUS),
            "Resets Sep 26"
        )
        XCTAssertEqual(
            ResetText.weekly(
                isoEnd: "2026-09-27T02:00:00+00:00",
                now: now,
                timeZone: TimeZone(secondsFromGMT: 0)!,
                locale: enUS
            ),
            "Resets Sep 27"
        )
    }

    func testWeeklyRejectsUnparseableTimestamp() {
        XCTAssertNil(
            ResetText.weekly(
                isoEnd: "not a date",
                now: at("2026-09-22T09:00:00+00:00"),
                timeZone: losAngeles,
                locale: enUS
            )
        )
    }

    func testFormatsUsedPercentAsInteger() {
        XCTAssertEqual(formatUsedPercent(13), "13%")
        XCTAssertEqual(formatUsedPercent(13.2), "13%")
        XCTAssertEqual(formatUsedPercent(13.5), "14%")
        XCTAssertEqual(formatUsedPercent(0.4), "0%")
    }

    func testFormatsCurrencyAmountsWithTheSymbolInFront() {
        XCTAssertEqual(formatAmount(37.6, unit: "$", locale: enUS), "$37.60")
        XCTAssertEqual(formatAmount(12.4, unit: "$", locale: enUS), "$12.40")
        XCTAssertEqual(formatAmount(0, unit: "$", locale: enUS), "$0.00")
        XCTAssertEqual(formatAmount(1234.5, unit: "$", locale: enUS), "$1,234.50")
        XCTAssertEqual(formatAmount(9.999, unit: "€", locale: enUS), "€10.00")
        XCTAssertEqual(formatAmount(5, unit: "£", locale: enUS), "£5.00")
    }

    func testFormatsOtherUnitsAsGroupedIntegersAfterTheNumber() {
        XCTAssertEqual(formatAmount(1240, unit: "tokens", locale: enUS), "1,240 tokens")
        XCTAssertEqual(formatAmount(1_250_000, unit: "tokens", locale: enUS), "1,250,000 tokens")
        XCTAssertEqual(formatAmount(12.4, unit: "requests", locale: enUS), "12 requests")
        XCTAssertEqual(formatAmount(12.6, unit: "requests", locale: enUS), "13 requests")
        XCTAssertEqual(formatAmount(42, unit: "", locale: enUS), "42")
    }

    func testWindowSessionReadsAsRemainingPercent() {
        let session = UsageSession(id: "5h", name: "5h limit", resetText: "Resets in 45m", usedPercent: 71)
        XCTAssertEqual(session.kind, .window)
        XCTAssertEqual(session.remainingFraction ?? 0, 0.29, accuracy: 0.0001)
        XCTAssertEqual(session.figureText(locale: enUS), "29%")
        XCTAssertEqual(session.captionText(locale: enUS), "Resets in 45m")
    }

    func testCappedCreditsSessionReadsAsRemainingAmount() {
        let session = UsageSession(
            id: "credits",
            name: "API credits",
            resetText: "Resets Oct 1",
            usedPercent: 24.8,
            kind: .credits(used: 12.4, cap: 50, unit: "$")
        )
        XCTAssertEqual(session.remainingFraction ?? 0, 0.752, accuracy: 0.0001)
        XCTAssertEqual(session.figureText(locale: enUS), "$37.60")
        XCTAssertEqual(session.captionText(locale: enUS), "used $12.40 of $50.00 · Resets Oct 1")
    }

    func testUncappedCreditsSessionReadsAsSpendWithNoBar() {
        let session = UsageSession(
            id: "spend",
            name: "Spend today",
            resetText: "",
            usedPercent: 0,
            kind: .credits(used: 12.4, cap: nil, unit: "$")
        )
        XCTAssertNil(session.remainingFraction, "no cap means there is no fraction to draw")
        XCTAssertEqual(session.figureText(locale: enUS), "$12.40")
        XCTAssertEqual(session.captionText(locale: enUS), "used this period")
    }

    func testUncappedCreditsSessionStillNamesItsReset() {
        let session = UsageSession(
            id: "spend",
            name: "Spend",
            resetText: "Resets Oct 1",
            usedPercent: 0,
            kind: .credits(used: 1240, cap: nil, unit: "tokens")
        )
        XCTAssertEqual(session.figureText(locale: enUS), "1,240 tokens")
        XCTAssertEqual(session.captionText(locale: enUS), "used this period · Resets Oct 1")
    }

    func testOverspentCreditsSessionClampsToAnEmptyBar() {
        let session = UsageSession(
            id: "credits",
            name: "API credits",
            resetText: "",
            usedPercent: 100,
            kind: .credits(used: 60, cap: 50, unit: "$")
        )
        XCTAssertEqual(session.remainingFraction, 0)
        XCTAssertEqual(session.figureText(locale: enUS), "$0.00")
        XCTAssertEqual(session.captionText(locale: enUS), "used $60.00 of $50.00")
    }

    func testSampleUsageShowsBothSessionKinds() throws {
        let agent = try XCTUnwrap(SampleUsage.agents.first { $0.id == "openai-api" })
        XCTAssertEqual(agent.name, "OpenAI API")
        let kinds = agent.sessions.map(\.kind)
        XCTAssertTrue(kinds.contains(.credits(used: 12.4, cap: 50, unit: "$")))
        XCTAssertTrue(kinds.contains(.credits(used: 3.28, cap: nil, unit: "$")))
        XCTAssertTrue(kinds.contains(.window))
    }

    func testSessionStackIsTheAgentSessionsArray() {
        let sessions = (0..<3).map { index in
            UsageSession(
                id: "s\(index)",
                name: "Session \(index)",
                resetText: "Resets Sep 26",
                usedPercent: Double(index)
            )
        }
        let agent = UsageAgent(id: "future", name: "Future", sessions: sessions, unavailableReason: nil)
        XCTAssertEqual(agent.sessions.count, 3)
        XCTAssertEqual(agent.sessions.map(\.id), sessions.map(\.id))
    }
}
