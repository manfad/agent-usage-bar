import XCTest
@testable import AgentUsage

final class ClaudeTests: XCTestCase {
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let enUS = Locale(identifier: "en_US")

    private func date(_ iso: String) -> Date {
        guard let date = ResetText.parseISO8601(iso) else {
            XCTFail("unparseable fixture date \(iso)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    func testParsesFiveHourWeeklyAndModelScopedLimits() throws {
        let json = """
        {
          "five_hour": {
            "utilization": 42.5,
            "resets_at": "2026-09-22T11:30:00.123456-07:00"
          },
          "seven_day": {
            "utilization": 13,
            "resets_at": "2026-09-26T08:21:18.802818-07:00"
          },
          "limits": [
            {
              "kind": "weekly_scoped",
              "group": "weekly",
              "percent": 61.2,
              "resets_at": "2026-09-26T08:21:18.802818-07:00",
              "is_active": true,
              "scope": { "model": { "display_name": "Fable" } }
            },
            {
              "kind": "five_hour",
              "group": "five_hour",
              "percent": 99,
              "resets_at": "2026-09-22T11:30:00.123456-07:00",
              "is_active": true,
              "scope": { "model": { "display_name": "Sonnet" } }
            }
          ]
        }
        """
        let sessions = try parseClaudeUsageSessions(
            Data(json.utf8),
            now: date("2026-09-22T09:00:00-07:00"),
            timeZone: losAngeles,
            locale: enUS
        )
        XCTAssertEqual(sessions.map(\.id), ["five_hour", "seven_day", "model_fable"])
        XCTAssertEqual(sessions.map(\.name), ["5h limit", "Weekly limit", "Fable"])
        XCTAssertEqual(sessions[0].usedPercent, 42.5)
        XCTAssertEqual(sessions[0].resetText, "Resets in 2h 30m")
        XCTAssertEqual(sessions[1].usedPercent, 13)
        XCTAssertEqual(sessions[1].resetText, "Resets Sep 26")
        XCTAssertEqual(sessions[2].usedPercent, 61.2)
        XCTAssertEqual(sessions[2].resetText, "Resets Sep 26")
    }

    func testParsesLegacySevenDayOpusWindowAlone() throws {
        let json = """
        {
          "seven_day_opus": {
            "utilization": 7,
            "resets_at": "2026-09-26T08:21:18.802818-07:00"
          }
        }
        """
        let sessions = try parseClaudeUsageSessions(
            Data(json.utf8),
            now: date("2026-09-22T09:00:00-07:00"),
            timeZone: losAngeles,
            locale: enUS
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "model_opus")
        XCTAssertEqual(sessions[0].name, "Opus")
        XCTAssertEqual(sessions[0].usedPercent, 7)
        XCTAssertEqual(sessions[0].resetText, "Resets Sep 26")
    }

    func testModelScopedLimitWinsOverLegacyWindowForSameModel() throws {
        let json = """
        {
          "seven_day_opus": {
            "utilization": 7,
            "resets_at": "2026-09-26T08:21:18.802818-07:00"
          },
          "limits": [
            {
              "kind": "weekly_scoped",
              "group": "weekly",
              "percent": 88,
              "resets_at": "2026-09-27T08:21:18.802818-07:00",
              "is_active": true,
              "scope": { "model": { "display_name": "Opus" } }
            }
          ]
        }
        """
        let sessions = try parseClaudeUsageSessions(
            Data(json.utf8),
            now: date("2026-09-22T09:00:00-07:00"),
            timeZone: losAngeles,
            locale: enUS
        )
        XCTAssertEqual(sessions.map(\.id), ["model_opus"])
        XCTAssertEqual(sessions[0].usedPercent, 88)
        XCTAssertEqual(sessions[0].resetText, "Resets Sep 27")
    }

    func testThrowsOnBadPayload() {
        XCTAssertThrowsError(try parseClaudeUsageSessions(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? ClaudeLoadError, .badPayload)
        }
        XCTAssertThrowsError(try parseClaudeUsageSessions(Data(#"{"five_hour": null}"#.utf8))) { error in
            XCTAssertEqual(error as? ClaudeLoadError, .badPayload)
        }
    }

    func testFiveHourWindowReadsAsACountdown() {
        XCTAssertEqual(
            ResetText.fiveHour(isoEnd: "2026-09-22T11:30:00.123456-07:00", now: date("2026-09-22T09:00:00-07:00")),
            "Resets in 2h 30m"
        )
        XCTAssertEqual(
            ResetText.fiveHour(isoEnd: "2026-09-22T09:45:00-07:00", now: date("2026-09-22T09:00:00-07:00")),
            "Resets in 45m"
        )
        XCTAssertEqual(
            ResetText.fiveHour(isoEnd: "2026-09-22T08:55:00-07:00", now: date("2026-09-22T09:00:00-07:00")),
            "Resets soon"
        )
        XCTAssertNil(ResetText.fiveHour(isoEnd: "", now: date("2026-09-22T09:00:00-07:00")))
    }

    func testWindowWithoutTimestampHasEmptyResetText() throws {
        let json = """
        { "five_hour": { "utilization": 5 } }
        """
        let sessions = try parseClaudeUsageSessions(
            Data(json.utf8),
            now: date("2026-09-22T09:00:00-07:00"),
            timeZone: losAngeles,
            locale: enUS
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].resetText, "")
        XCTAssertEqual(sessions[0].usedPercent, 5)
    }

    func testWeeklyWindowInsideTheFinalDayCountsDown() throws {
        let json = """
        {
          "seven_day": {
            "utilization": 91,
            "resets_at": "2026-09-22T14:10:00-07:00"
          }
        }
        """
        let sessions = try parseClaudeUsageSessions(
            Data(json.utf8),
            now: date("2026-09-22T09:00:00-07:00"),
            timeZone: losAngeles,
            locale: enUS
        )
        XCTAssertEqual(sessions[0].resetText, "Resets in 5h 10m")
    }

    func testCredentialParsingReadsOAuthBlob() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"t","refreshToken":"r","expiresAt":1790000000000,"scopes":["user:inference"],"subscriptionType":"max"}}"#
        let credentials = try ClaudeAuth.parseCredentials(Data(json.utf8))
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1790000000))
        XCTAssertEqual(credentials.subscriptionType, "max")
        XCTAssertFalse(credentials.accessToken.isEmpty)
    }

    func testExpiredCredentialsSurfaceSignInExpired() {
        let credentials = ClaudeCredentials(
            accessToken: "t",
            expiresAt: Date(timeIntervalSince1970: 1_000_000),
            subscriptionType: nil
        )
        XCTAssertThrowsError(try ClaudeAuth.validated(credentials, now: Date(timeIntervalSince1970: 2_000_000))) { error in
            XCTAssertEqual(error as? ClaudeLoadError, .signInExpired)
        }
        XCTAssertNoThrow(try ClaudeAuth.validated(credentials, now: Date(timeIntervalSince1970: 500_000)))
    }

    func testStatusLabelIsTheHighestSessionAcrossAgents() {
        let grok = UsageAgent(
            id: "grok",
            name: "Grok",
            sessions: [UsageSession(id: "weekly", name: "Weekly limit", resetText: "", usedPercent: 13)],
            unavailableReason: nil
        )
        let claude = UsageAgent(
            id: "claude",
            name: "Claude",
            sessions: [
                UsageSession(id: "five_hour", name: "5h limit", resetText: "", usedPercent: 42.5),
                UsageSession(id: "seven_day", name: "Weekly limit", resetText: "", usedPercent: 71.4),
            ],
            unavailableReason: nil
        )
        XCTAssertEqual(StatusText.label(for: [grok, claude]), "71%")
        XCTAssertEqual(StatusText.label(for: [grok]), "13%")
        XCTAssertEqual(StatusText.label(for: []), "—")
        XCTAssertEqual(
            StatusText.label(for: [UsageAgent(id: "claude", name: "Claude", sessions: [], unavailableReason: "Not signed in")]),
            "—"
        )
    }
}
