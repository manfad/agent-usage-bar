import XCTest
@testable import AgentUsage

final class PluginTests: XCTestCase {
    func testRemainingPercentIsInvertedToUsed() throws {
        let json = """
        { "sessions": [
            { "id": "weekly", "name": "Weekly limit", "remainingPercent": 16 },
            { "id": "five_hour", "name": "5h limit", "usedPercent": 26 }
        ] }
        """
        let parsed = try parsePluginSessions(Data(json.utf8), now: Date())
        XCTAssertEqual(parsed.sessions.map(\.usedPercent), [84, 26])
    }

    private var scratch: URL!
    private var restoreHome: String??

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-usage-plugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let restoreHome {
            if let value = restoreHome {
                setenv("AGENT_USAGE_HOME", value, 1)
            } else {
                unsetenv("AGENT_USAGE_HOME")
            }
            self.restoreHome = nil
        }
        // Leave the shared catalogue empty so nothing leaks into another case.
        ProviderCatalog.scan(in: scratch.appendingPathComponent("gone", isDirectory: true))
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
    }

    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let enUS = Locale(identifier: "en_US")

    private func at(_ iso: String) -> Date {
        guard let date = ResetText.parseISO8601(iso) else {
            XCTFail("unparseable fixture date \(iso)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    /// `$AGENT_USAGE_HOME/providers/<id>/…`, the layout the app discovers.
    private func makeProvider(
        _ id: String,
        manifest: String,
        script: (name: String, body: String)? = nil,
        icon: (name: String, body: String)? = nil,
        home: URL? = nil
    ) throws -> URL {
        let folder = (home ?? scratch)
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("provider.json"))
        if let script {
            let url = folder.appendingPathComponent(script.name)
            try Data(script.body.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }
        if let icon {
            try Data(icon.body.utf8).write(to: folder.appendingPathComponent(icon.name))
        }
        return folder
    }

    private func useScratchAsHome() {
        restoreHome = ProcessInfo.processInfo.environment["AGENT_USAGE_HOME"]
        setenv("AGENT_USAGE_HOME", scratch.path, 1)
    }

    // MARK: - Manifest decoding

    func testDecodesModeAManifest() throws {
        let manifest = try ProviderManifest.decode(Data("""
        {
          "name": "Cursor",
          "icon": "icon.svg",
          "color": "#D97757",
          "fetch": "./fetch.sh"
        }
        """.utf8))
        XCTAssertEqual(manifest.name, "Cursor")
        XCTAssertEqual(manifest.icon, "icon.svg")
        XCTAssertEqual(manifest.color, "#D97757")
        XCTAssertEqual(manifest.mode, .command("./fetch.sh"))
    }

    func testDecodesModeBManifest() throws {
        let manifest = try ProviderManifest.decode(Data("""
        {
          "name": "Example",
          "request": {
            "url": "https://api.example.com/usage",
            "method": "GET",
            "headers": { "Authorization": "Bearer {{token}}" }
          },
          "token": { "file": "~/.grok/auth.json", "path": "*.key" },
          "sessions": [
            {
              "id": "weekly",
              "name": "Weekly limit",
              "usedPercent": "config.creditUsagePercent",
              "resetsAt": "config.currentPeriod.end"
            },
            {
              "id": "credits",
              "name": "API credits",
              "kind": "credits",
              "used": "usage.total_usd",
              "cap": "limit.usd",
              "unit": "$"
            }
          ]
        }
        """.utf8))
        guard case let .request(request, sessions) = manifest.mode else {
            return XCTFail("expected mode B")
        }
        XCTAssertEqual(request.url, "https://api.example.com/usage")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers?["Authorization"], "Bearer {{token}}")
        XCTAssertEqual(manifest.token?.file, "~/.grok/auth.json")
        XCTAssertEqual(manifest.token?.path, "*.key")
        XCTAssertEqual(sessions.map(\.id), ["weekly", "credits"])
        XCTAssertNil(sessions[0].kind)
        XCTAssertEqual(sessions[1].kind, "credits")
        XCTAssertEqual(sessions[1].used, "usage.total_usd")
        XCTAssertEqual(sessions[1].cap, "limit.usd")
    }

    func testFetchWinsOverRequestWhenBothArePresent() throws {
        let manifest = try ProviderManifest.decode(Data("""
        {
          "name": "Both",
          "fetch": "./fetch.sh",
          "request": { "url": "https://api.example.com/usage" },
          "sessions": [{ "id": "weekly", "usedPercent": "a" }]
        }
        """.utf8))
        XCTAssertEqual(manifest.mode, .command("./fetch.sh"))
    }

    func testRejectsManifestWithNeitherMode() {
        XCTAssertThrowsError(try ProviderManifest.decode(Data("""
        { "name": "Nothing" }
        """.utf8))) { error in
            XCTAssertEqual(error as? PluginError, .malformedManifest)
        }
    }

    func testRejectsManifestWithNoName() {
        XCTAssertThrowsError(try ProviderManifest.decode(Data("""
        { "fetch": "./fetch.sh" }
        """.utf8))) { error in
            XCTAssertEqual(error as? PluginError, .malformedManifest)
        }
    }

    func testRejectsModeBWithNoSessionMappings() {
        XCTAssertThrowsError(try ProviderManifest.decode(Data("""
        { "name": "Example", "request": { "url": "https://api.example.com/usage" } }
        """.utf8))) { error in
            XCTAssertEqual(error as? PluginError, .malformedManifest)
        }
    }

    // MARK: - Dotted paths

    private var pathFixture: Any {
        let json = """
        {
          "config": { "currentPeriod": { "end": "2026-09-26T08:00:00Z" }, "creditUsagePercent": 16.5 },
          "data": [
            { "results": [{ "amount": { "value": 4.25, "currency": "usd" } }] },
            { "results": [] }
          ],
          "auth": {
            "https://auth.x.ai::client": { "key": "first-entry" },
            "zzz": { "key": "last-entry" }
          },
          "single": { "https://auth.x.ai::client": { "key": "only-entry" } },
          "nothing": null
        }
        """
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [:]
    }

    func testResolvesNestedPath() {
        XCTAssertEqual(
            jsonPathValue(pathFixture, path: "config.currentPeriod.end") as? String,
            "2026-09-26T08:00:00Z"
        )
        XCTAssertEqual(jsonDouble(jsonPathValue(pathFixture, path: "config.creditUsagePercent")), 16.5)
    }

    func testResolvesArrayIndex() {
        XCTAssertEqual(
            jsonDouble(jsonPathValue(pathFixture, path: "data.0.results.0.amount.value")),
            4.25
        )
        XCTAssertNil(jsonPathValue(pathFixture, path: "data.1.results.0.amount.value"))
        XCTAssertNil(jsonPathValue(pathFixture, path: "data.9.results"))
    }

    func testStarTakesTheFirstObjectValue() {
        // Sorted by key, so the answer does not depend on dictionary ordering.
        XCTAssertEqual(jsonPathValue(pathFixture, path: "auth.*.key") as? String, "first-entry")
        // The shape `*.key` is written for: one entry, whatever it happens to be called.
        XCTAssertEqual(jsonPathValue(pathFixture, path: "single.*.key") as? String, "only-entry")
        // `*` on an array takes its first element.
        XCTAssertEqual(jsonPathValue(pathFixture, path: "data.*.results.*.amount.currency") as? String, "usd")
    }

    func testMissingAndNullPathsResolveToNil() {
        XCTAssertNil(jsonPathValue(pathFixture, path: "config.nope"))
        XCTAssertNil(jsonPathValue(pathFixture, path: "nothing"))
        XCTAssertNil(jsonPathValue(pathFixture, path: "config..end"))
        XCTAssertNil(jsonPathValue(nil, path: "config"))
    }

    // MARK: - Token

    func testSubstitutesTokenPlaceholder() {
        XCTAssertEqual(
            substitutePluginToken(in: "Bearer {{token}}", token: "abc"),
            "Bearer abc"
        )
        XCTAssertEqual(
            substitutePluginToken(in: "https://x/?k={{token}}&v={{token}}", token: "abc"),
            "https://x/?k=abc&v=abc"
        )
        XCTAssertEqual(
            substitutePluginToken(in: "no placeholder", token: "abc"),
            "no placeholder"
        )
    }

    func testResolvesTokenFromEnvironment() throws {
        setenv("AGENT_USAGE_TEST_TOKEN", "env-value", 1)
        defer { unsetenv("AGENT_USAGE_TEST_TOKEN") }
        let spec = ProviderManifest.TokenSpec(env: "AGENT_USAGE_TEST_TOKEN")
        XCTAssertEqual(try PluginToken.resolve(spec, folder: scratch), "env-value")
    }

    func testResolvesTokenFromJSONFileByPath() throws {
        let url = scratch.appendingPathComponent("auth.json")
        try Data("""
        { "https://auth.x.ai::client": { "key": "file-value" } }
        """.utf8).write(to: url)
        let spec = ProviderManifest.TokenSpec(file: url.path, path: "*.key")
        XCTAssertEqual(try PluginToken.resolve(spec, folder: scratch), "file-value")
    }

    func testResolvesTokenFromWholeFileWhenNoPathIsGiven() throws {
        let url = scratch.appendingPathComponent("token.txt")
        try Data("  plain-value\n".utf8).write(to: url)
        let spec = ProviderManifest.TokenSpec(file: "token.txt")
        XCTAssertEqual(try PluginToken.resolve(spec, folder: scratch), "plain-value")
    }

    func testResolvesTokenFromCommandStdout() throws {
        let spec = ProviderManifest.TokenSpec(command: "printf 'shell-value\\n'")
        XCTAssertEqual(try PluginToken.resolve(spec, folder: scratch), "shell-value")
    }

    func testMissingTokenSourcesThrow() {
        XCTAssertThrowsError(
            try PluginToken.resolve(ProviderManifest.TokenSpec(env: "AGENT_USAGE_NOT_SET"), folder: scratch)
        ) { XCTAssertEqual($0 as? PluginError, .missingToken) }
        XCTAssertThrowsError(
            try PluginToken.resolve(ProviderManifest.TokenSpec(file: "absent.json"), folder: scratch)
        ) { XCTAssertEqual($0 as? PluginError, .missingToken) }
        XCTAssertThrowsError(
            try PluginToken.resolve(ProviderManifest.TokenSpec(), folder: scratch)
        ) { XCTAssertEqual($0 as? PluginError, .malformedManifest) }
    }

    // MARK: - Normalized payload

    func testNormalizedPayloadBecomesWindowAndCreditsSessions() throws {
        let json = """
        {
          "sessions": [
            { "id": "five_hour", "name": "5h limit", "kind": "window", "usedPercent": 26,
              "resetsAt": "2026-09-22T14:00:00Z" },
            { "id": "credits", "name": "API credits", "kind": "credits", "used": 12.4,
              "cap": 50, "unit": "$", "resetsAt": "2026-10-01T00:00:00Z" }
          ]
        }
        """
        let parsed = try parsePluginSessions(
            Data(json.utf8),
            now: at("2026-09-22T09:00:00+00:00"),
            timeZone: losAngeles,
            locale: enUS
        )
        XCTAssertNil(parsed.error)
        XCTAssertEqual(parsed.sessions.count, 2)

        let window = parsed.sessions[0]
        XCTAssertEqual(window.name, "5h limit")
        XCTAssertEqual(window.kind, .window)
        XCTAssertEqual(window.usedPercent, 26)
        XCTAssertEqual(window.resetText, "Resets in 5h")

        let credits = parsed.sessions[1]
        XCTAssertEqual(credits.kind, .credits(used: 12.4, cap: 50, unit: "$"))
        XCTAssertEqual(credits.usedPercent, 24.8, accuracy: 0.0001)
        XCTAssertEqual(credits.resetText, "Resets Sep 30")
        XCTAssertEqual(credits.figureText(locale: enUS), "$37.60")
        XCTAssertEqual(credits.captionText(locale: enUS), "of $50 · Resets Sep 30")
    }

    func testCreditsWithoutCapHasNoFractionAndDefaultsItsUnit() throws {
        let json = """
        { "sessions": [{ "id": "spend", "kind": "credits", "used": "12.4" }] }
        """
        let parsed = try parsePluginSessions(Data(json.utf8), now: at("2026-09-22T09:00:00+00:00"))
        let session = try XCTUnwrap(parsed.sessions.first)
        XCTAssertEqual(session.kind, .credits(used: 12.4, cap: nil, unit: "$"))
        XCTAssertEqual(session.name, "spend", "a session with no name falls back to its id")
        XCTAssertEqual(session.usedPercent, 0)
        XCTAssertNil(session.remainingFraction)
        XCTAssertEqual(session.resetText, "")
    }

    func testRemainingWithACapBecomesTheSpendAgainstIt() throws {
        let json = """
        { "sessions": [{ "id": "credits", "name": "Balance", "kind": "credits",
                         "remaining": 21.5, "cap": 100, "unit": "¥" }] }
        """
        let parsed = try parsePluginSessions(Data(json.utf8), now: at("2026-09-22T09:00:00+00:00"))
        let session = try XCTUnwrap(parsed.sessions.first)
        XCTAssertEqual(session.kind, .credits(used: 78.5, cap: 100, unit: "¥"))
        XCTAssertEqual(session.usedPercent, 78.5, accuracy: 0.0001)
        XCTAssertEqual(session.remainingFraction ?? 0, 0.215, accuracy: 0.0001)
        XCTAssertEqual(session.figureText(locale: enUS), "¥21.50")
        XCTAssertEqual(session.captionText(locale: enUS), "of ¥100")
    }

    func testRemainingWithNoCapBecomesABalance() throws {
        let json = """
        { "sessions": [{ "id": "credits", "name": "Balance", "kind": "credits",
                         "remaining": "21.47", "unit": "¥" }] }
        """
        let parsed = try parsePluginSessions(Data(json.utf8), now: at("2026-09-22T09:00:00+00:00"))
        let session = try XCTUnwrap(parsed.sessions.first)
        XCTAssertEqual(session.kind, .balance(remaining: 21.47, unit: "¥"))
        XCTAssertEqual(session.usedPercent, 0)
        XCTAssertNil(session.remainingFraction)
        XCTAssertEqual(session.figureText(locale: enUS), "¥21.47")
        XCTAssertEqual(session.captionText(locale: enUS), "balance")
    }

    func testUsedWinsOverRemainingAndACreditsRowWithNeitherIsDropped() throws {
        let json = """
        {
          "sessions": [
            { "id": "spend", "kind": "credits", "used": 12.4, "remaining": 99, "cap": 50 },
            { "id": "nothing", "kind": "credits", "cap": 50, "unit": "$" }
          ]
        }
        """
        let parsed = try parsePluginSessions(Data(json.utf8), now: at("2026-09-22T09:00:00+00:00"))
        XCTAssertEqual(parsed.sessions.map(\.id), ["spend"])
        XCTAssertEqual(parsed.sessions[0].kind, .credits(used: 12.4, cap: 50, unit: "$"))
    }

    func testBalanceUnitDefaultsAndACapOfZeroIsIgnored() throws {
        let json = """
        { "sessions": [{ "id": "credits", "kind": "credits", "remaining": 8, "cap": 0 }] }
        """
        let parsed = try parsePluginSessions(Data(json.utf8), now: at("2026-09-22T09:00:00+00:00"))
        let session = try XCTUnwrap(parsed.sessions.first)
        XCTAssertEqual(session.kind, .balance(remaining: 8, unit: "$"))
        XCTAssertEqual(session.figureText(locale: enUS), "$8")
    }

    func testABalanceAboveItsCapClampsTheSpendToZero() throws {
        let json = """
        { "sessions": [{ "id": "credits", "kind": "credits", "remaining": 120, "cap": 100,
                         "unit": "¥" }] }
        """
        let parsed = try parsePluginSessions(Data(json.utf8), now: at("2026-09-22T09:00:00+00:00"))
        let session = try XCTUnwrap(parsed.sessions.first)
        XCTAssertEqual(session.kind, .credits(used: 0, cap: 100, unit: "¥"))
        XCTAssertEqual(session.usedPercent, 0)
        XCTAssertEqual(session.figureText(locale: enUS), "¥100")
    }

    func testPayloadErrorIsReportedAndBadRowsAreDropped() throws {
        let json = """
        {
          "sessions": [
            { "id": "weekly" },
            { "name": "no id", "usedPercent": 10 },
            { "id": "weekly", "usedPercent": 10 },
            { "id": "weekly", "usedPercent": 90 }
          ],
          "error": "Sign-in expired"
        }
        """
        let parsed = try parsePluginSessions(Data(json.utf8), now: at("2026-09-22T09:00:00+00:00"))
        XCTAssertEqual(parsed.error, "Sign-in expired")
        // The row with no measurement and the one with no id go; the first usable `weekly` wins.
        XCTAssertEqual(parsed.sessions.map(\.id), ["weekly"])
        XCTAssertEqual(parsed.sessions.first?.usedPercent, 10)
    }

    func testUnparseablePayloadThrows() {
        XCTAssertThrowsError(try parsePluginSessions(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? PluginError, .badPayload)
        }
    }

    // MARK: - Mode B mapping

    func testModeBMappingProducesTheNormalizedShape() throws {
        let response = try JSONSerialization.jsonObject(with: Data("""
        {
          "config": { "creditUsagePercent": 16.5, "currentPeriod": { "end": "2026-09-26T08:00:00Z" } },
          "usage": { "total_usd": 12.4 },
          "limit": { "usd": 50 },
          "period": { "end": "2026-10-01T00:00:00Z" }
        }
        """.utf8))
        let mappings = [
            ProviderManifest.SessionMapping(
                id: "weekly",
                name: "Weekly limit",
                kind: "window",
                usedPercent: "config.creditUsagePercent",
                resetsAt: "config.currentPeriod.end"
            ),
            ProviderManifest.SessionMapping(
                id: "credits",
                name: "API credits",
                kind: "credits",
                used: "usage.total_usd",
                cap: "limit.usd",
                unit: "$",
                resetsAt: "period.end"
            ),
            ProviderManifest.SessionMapping(
                id: "absent",
                name: "Not in the response",
                usedPercent: "nope.nope"
            )
        ]
        let payload = pluginNormalizedPayload(from: response, mappings: mappings)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let parsed = try parsePluginSessions(
            data,
            now: at("2026-09-22T09:00:00+00:00"),
            timeZone: losAngeles,
            locale: enUS
        )
        XCTAssertEqual(parsed.sessions.map(\.id), ["weekly", "credits"])
        XCTAssertEqual(parsed.sessions[0].usedPercent, 16.5)
        XCTAssertEqual(parsed.sessions[0].resetText, "Resets Sep 26")
        XCTAssertEqual(parsed.sessions[1].kind, .credits(used: 12.4, cap: 50, unit: "$"))
        XCTAssertEqual(parsed.sessions[1].resetText, "Resets Sep 30")
    }

    func testModeBMappingReadsARemainingBalance() throws {
        let response = try JSONSerialization.jsonObject(with: Data("""
        { "data": { "available_balance": 21.47 }, "plan": { "topUp": 100 } }
        """.utf8))
        let balanceOnly = pluginNormalizedPayload(
            from: response,
            mappings: [
                ProviderManifest.SessionMapping(
                    id: "credits",
                    name: "Balance",
                    kind: "credits",
                    remaining: "data.available_balance",
                    unit: "¥"
                )
            ]
        )
        var parsed = try parsePluginSessions(
            try JSONSerialization.data(withJSONObject: balanceOnly),
            now: at("2026-09-22T09:00:00+00:00"),
            locale: enUS
        )
        XCTAssertEqual(parsed.sessions.map(\.kind), [.balance(remaining: 21.47, unit: "¥")])
        XCTAssertEqual(parsed.sessions.first?.figureText(locale: enUS), "¥21.47")

        // The same balance, now with a cap mapped: it becomes a spend against that cap.
        let againstACap = pluginNormalizedPayload(
            from: response,
            mappings: [
                ProviderManifest.SessionMapping(
                    id: "credits",
                    name: "Balance",
                    kind: "credits",
                    remaining: "data.available_balance",
                    cap: "plan.topUp",
                    unit: "¥"
                )
            ]
        )
        parsed = try parsePluginSessions(
            try JSONSerialization.data(withJSONObject: againstACap),
            now: at("2026-09-22T09:00:00+00:00"),
            locale: enUS
        )
        let session = try XCTUnwrap(parsed.sessions.first)
        XCTAssertEqual(session.remainingFraction ?? 0, 0.2147, accuracy: 0.0001)
        XCTAssertEqual(session.figureText(locale: enUS), "¥21.47")
        XCTAssertEqual(session.captionText(locale: enUS), "of ¥100")

        // A credits mapping with neither path drops the row, the same as a missing percentage.
        let neither = pluginNormalizedPayload(
            from: response,
            mappings: [
                ProviderManifest.SessionMapping(id: "credits", kind: "credits", cap: "plan.topUp")
            ]
        )
        XCTAssertEqual((neither["sessions"] as? [Any])?.count, 0)
    }

    // MARK: - Discovery

    func testDiscoveryDirectoryFollowsAgentUsageHome() {
        useScratchAsHome()
        XCTAssertEqual(
            ProviderCatalog.directoryURL().standardizedFileURL.path,
            scratch.appendingPathComponent("providers").standardizedFileURL.path
        )
    }

    func testScanReadsFoldersAndIgnoresMalformedOnes() throws {
        _ = try makeProvider("cursor", manifest: """
        { "name": "Cursor", "icon": "icon.svg", "fetch": "./fetch.sh" }
        """, script: (name: "fetch.sh", body: "#!/bin/sh\necho '{}'\n"), icon: (name: "icon.svg", body: iconSVG))
        // No provider.json at all.
        try FileManager.default.createDirectory(
            at: scratch.appendingPathComponent("providers/empty", isDirectory: true),
            withIntermediateDirectories: true
        )
        // Unparseable provider.json.
        _ = try makeProvider("broken", manifest: "{ not json")
        // Parseable, but names neither a command nor a request.
        _ = try makeProvider("pointless", manifest: """
        { "name": "Pointless" }
        """)
        // A loose file beside the folders.
        try Data("stray".utf8).write(to: scratch.appendingPathComponent("providers/README"))

        let providers = ProviderCatalog.scan(in: scratch.appendingPathComponent("providers"))
        XCTAssertEqual(providers.map(\.id), ["cursor"])
        XCTAssertEqual(ProviderCatalog.names, ["cursor": "Cursor"])
        XCTAssertEqual(ProviderCatalog.chrome(for: "cursor")?.iconURL?.lastPathComponent, "icon.svg")
        XCTAssertEqual(AgentPreferences.displayName(for: "cursor"), "Cursor")
    }

    func testScanOfAMissingDirectoryIsEmpty() {
        let providers = ProviderCatalog.scan(in: scratch.appendingPathComponent("nowhere"))
        XCTAssertTrue(providers.isEmpty)
        XCTAssertTrue(ProviderCatalog.names.isEmpty)
    }

    func testPluginOverridesABuiltInIDInPlace() throws {
        useScratchAsHome()
        _ = try makeProvider("claude", manifest: """
        { "name": "Claude (plugin)", "fetch": "./fetch.sh" }
        """, script: (name: "fetch.sh", body: "#!/bin/sh\necho '{}'\n"))
        _ = try makeProvider("cursor", manifest: """
        { "name": "Cursor", "fetch": "./fetch.sh" }
        """, script: (name: "fetch.sh", body: "#!/bin/sh\necho '{}'\n"))

        let sources = AgentRegistry.sources()
        // Built-in order is kept, the override lands in Claude's place, new ids follow.
        XCTAssertEqual(sources.map(\.id), ["grok", "claude", "cursor"])
        XCTAssertTrue(sources[0] is GrokAgentSource)
        XCTAssertTrue(sources[1] is PluginProvider, "the folder replaces the built-in Claude source")
        XCTAssertEqual((sources[1] as? PluginProvider)?.name, "Claude (plugin)")
        XCTAssertEqual(AgentPreferences.displayName(for: "claude"), "Claude (plugin)")
        XCTAssertEqual(AgentRegistry.knownIDs(), ["grok", "claude", "cursor"])
    }

    // MARK: - End to end

    func testModeAScriptIsDiscoveredAndLoaded() async throws {
        useScratchAsHome()
        _ = try makeProvider("cursor", manifest: """
        {
          "name": "Cursor",
          "icon": "icon.svg",
          "color": "#D97757",
          "fetch": "./fetch.sh"
        }
        """, script: (name: "fetch.sh", body: """
        #!/bin/sh
        # No network: the fixture stands in for a real call.
        cat <<'JSON'
        { "sessions": [
            { "id": "five_hour", "name": "5h limit", "kind": "window", "usedPercent": 26,
              "resetsAt": "2026-09-22T14:00:00Z" },
            { "id": "credits", "name": "API credits", "kind": "credits", "used": 12.4,
              "cap": 50, "unit": "$" }
          ] }
        JSON
        """), icon: (name: "icon.svg", body: iconSVG))

        let source = try XCTUnwrap(AgentRegistry.sources().first { $0.id == "cursor" })
        let agent = await source.load()
        XCTAssertNil(agent.unavailableReason)
        XCTAssertEqual(agent.name, "Cursor")
        XCTAssertEqual(agent.sessions.map(\.id), ["five_hour", "credits"])
        XCTAssertEqual(agent.sessions[0].usedPercent, 26)
        XCTAssertEqual(agent.sessions[1].kind, .credits(used: 12.4, cap: 50, unit: "$"))
        XCTAssertNotNil(AgentIcons.brandColor(for: "cursor"))
    }

    func testAScriptThatFailsBecomesAnUnavailableReason() async throws {
        let folder = try makeProvider("broken-script", manifest: """
        { "name": "Broken", "fetch": "./fetch.sh" }
        """, script: (name: "fetch.sh", body: "#!/bin/sh\nexit 1\n"))
        let provider = try XCTUnwrap(PluginProvider(folder: folder))
        let agent = await provider.load()
        XCTAssertTrue(agent.sessions.isEmpty)
        XCTAssertEqual(agent.unavailableReason, "Broken script failed")
    }

    func testAScriptReportingAnErrorShowsThatError() async throws {
        let folder = try makeProvider("expired", manifest: """
        { "name": "Expired", "fetch": "./fetch.sh" }
        """, script: (name: "fetch.sh", body: """
        #!/bin/sh
        echo '{ "sessions": [], "error": "Sign-in expired" }'
        """))
        let provider = try XCTUnwrap(PluginProvider(folder: folder))
        let agent = await provider.load()
        XCTAssertEqual(agent.unavailableReason, "Sign-in expired")
    }

    func testAScriptWithoutTheExecutableBitStillRuns() async throws {
        let folder = scratch
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("unmarked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
        { "name": "Unmarked", "fetch": "fetch.sh" }
        """.utf8).write(to: folder.appendingPathComponent("provider.json"))
        let script = folder.appendingPathComponent("fetch.sh")
        try Data("echo '{ \"sessions\": [{ \"id\": \"w\", \"usedPercent\": 5 }] }'\n".utf8)
            .write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)

        let provider = try XCTUnwrap(PluginProvider(folder: folder))
        let agent = await provider.load()
        XCTAssertEqual(agent.sessions.map(\.usedPercent), [5])
    }

    func testCommandTimeoutIsEnforced() {
        let data = PluginCommand.run("sleep 5", in: scratch, timeout: 0.5)
        XCTAssertNil(data)
    }

    // MARK: - Icons

    func testParsesBrandColourHex() {
        let color = AgentIcons.color(hex: "#D97757")
        XCTAssertEqual(color?.redComponent ?? 0, 0xD9 / 255, accuracy: 0.001)
        XCTAssertEqual(color?.greenComponent ?? 0, 0x77 / 255, accuracy: 0.001)
        XCTAssertEqual(color?.blueComponent ?? 0, 0x57 / 255, accuracy: 0.001)
        XCTAssertEqual(AgentIcons.color(hex: "fff")?.redComponent, 1)
        XCTAssertEqual(AgentIcons.color(hex: "#000000ff")?.alphaComponent, 1)
        XCTAssertNil(AgentIcons.color(hex: "not a colour"))
        XCTAssertNil(AgentIcons.color(hex: "#12345"))
    }

    func testPluginIconIsLoadedAsATemplate() throws {
        _ = try makeProvider("cursor", manifest: """
        { "name": "Cursor", "icon": "icon.svg", "fetch": "./fetch.sh" }
        """, icon: (name: "icon.svg", body: iconSVG))
        ProviderCatalog.scan(in: scratch.appendingPathComponent("providers"))
        let image = try XCTUnwrap(AgentIcons.image(for: "cursor"))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.width, 24)
    }

    private let iconSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">\
    <circle cx="12" cy="12" r="9" fill="white"/></svg>
    """
}
