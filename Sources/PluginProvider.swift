import Foundation

/// Providers the user adds by dropping a folder next to the app's config, with no rebuild.
///
/// A folder under `$AGENT_USAGE_HOME/providers` (or `~/.config/agent-usage/providers`) holds a
/// `provider.json` and, optionally, a fetch script and a template SVG. The folder name is the
/// agent id. Two ways to get numbers out of a service:
///
/// - **Mode A** — `"fetch"` names a command that prints the normalized JSON on stdout.
/// - **Mode B** — `"request"` describes an HTTP call and `"sessions"` maps dotted paths in the
///   response onto session rows. Mode B is mapped into the same normalized shape internally, so
///   both modes land in one parser.
///
/// Nothing here ever writes a credential back, and no token value is ever logged.
enum PluginError: Error, Equatable {
    case malformedManifest
    case missingToken
    case unreadableToken
    case commandFailed
    case badPayload
    case signInExpired
    case network
}

/// The default unit for a credits session, since a balance without a currency reads as broken.
let defaultCreditsUnit = "$"

/// The placeholder a manifest uses where the resolved token belongs.
let pluginTokenPlaceholder = "{{token}}"

// MARK: - Manifest

/// `provider.json`. Hand-authored and fixed in shape, so `Codable` earns its keep here; the
/// payloads providers return are parsed the lenient way instead, further down.
struct ProviderManifest: Codable, Equatable, Sendable {
    var name: String
    var icon: String?
    var color: String?
    var fetch: String?
    var request: RequestSpec?
    var token: TokenSpec?
    var sessions: [SessionMapping]?

    struct RequestSpec: Codable, Equatable, Sendable {
        var url: String
        var method: String?
        var headers: [String: String]?
    }

    /// Exactly one of `file`, `command` or `env` supplies the token. `path` reads it out of the
    /// JSON that source produces; without `path` the whole trimmed value is the token.
    struct TokenSpec: Codable, Equatable, Sendable {
        var file: String?
        var command: String?
        var env: String?
        var path: String?
    }

    struct SessionMapping: Codable, Equatable, Sendable {
        var id: String
        var name: String?
        var kind: String?
        var usedPercent: String?
        /// For APIs that report what is left rather than what is used (Grok does).
        var remainingPercent: String?
        var used: String?
        /// For prepaid billing that reports what is left rather than what was spent.
        var remaining: String?
        var cap: String?
        var unit: String?
        var resetsAt: String?
    }

    enum Mode: Equatable, Sendable {
        case command(String)
        case request(RequestSpec, [SessionMapping])
    }

    /// A command wins when both are present, and a manifest with neither is not a provider.
    var mode: Mode? {
        if let fetch, !fetch.pluginTrimmed.isEmpty {
            return .command(fetch)
        }
        if let request, !request.url.pluginTrimmed.isEmpty, let sessions, !sessions.isEmpty {
            return .request(request, sessions)
        }
        return nil
    }

    static func decode(_ data: Data) throws -> ProviderManifest {
        guard let manifest = try? JSONDecoder().decode(ProviderManifest.self, from: data) else {
            throw PluginError.malformedManifest
        }
        guard !manifest.name.pluginTrimmed.isEmpty, manifest.mode != nil else {
            throw PluginError.malformedManifest
        }
        return manifest
    }
}

// MARK: - Dotted JSON paths

/// Resolves `config.currentPeriod.end`, `data.0.amount.value` or `*.key` against parsed JSON.
///
/// A numeric component indexes an array (after trying it as an object key). `*` takes the first
/// value of an object — by sorted key, so the answer never depends on dictionary ordering — or
/// the first element of an array.
func jsonPathValue(_ root: Any?, path: String) -> Any? {
    guard !path.isEmpty else { return root }
    var current = root
    for component in path.split(separator: ".", omittingEmptySubsequences: false) {
        let key = String(component)
        if key.isEmpty { return nil }
        if key == "*" {
            if let object = current as? [String: Any] {
                current = object.keys.sorted().first.flatMap { object[$0] }
            } else if let array = current as? [Any] {
                current = array.first
            } else {
                return nil
            }
            continue
        }
        if let object = current as? [String: Any], let value = object[key] {
            current = value
            continue
        }
        if let array = current as? [Any], let index = Int(key), index >= 0, index < array.count {
            current = array[index]
            continue
        }
        return nil
    }
    return current is NSNull ? nil : current
}

func substitutePluginToken(in template: String, token: String) -> String {
    template.replacingOccurrences(of: pluginTokenPlaceholder, with: token)
}

// MARK: - Normalized payload

/// The JSON a mode A command prints, and what mode B mapping produces internally.
///
/// Numbers are read leniently (a shell script that prints `"26"` is still telling us 26), unknown
/// session kinds fall back to a window, and a session missing its measurement is dropped rather
/// than shown as zero.
func parsePluginSessions(
    _ data: Data,
    now: Date = Date(),
    timeZone: TimeZone = .current,
    locale: Locale = .current
) throws -> (sessions: [UsageSession], error: String?) {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw PluginError.badPayload
    }
    var sessions: [UsageSession] = []
    var seen = Set<String>()
    // Claimed only once a row is really usable, so a row missing its measurement cannot shadow a
    // later row that carries the same id.
    func append(_ session: UsageSession) {
        guard seen.insert(session.id).inserted else { return }
        sessions.append(session)
    }
    for entry in root["sessions"] as? [Any] ?? [] {
        guard let raw = entry as? [String: Any],
              let id = (raw["id"] as? String)?.pluginTrimmed, !id.isEmpty,
              !seen.contains(id) else {
            continue
        }
        let name = (raw["name"] as? String)?.pluginTrimmed
        let resetText = (raw["resetsAt"] as? String).flatMap {
            ResetText.auto(isoEnd: $0, now: now, timeZone: timeZone, locale: locale)
        } ?? ""
        let kind = (raw["kind"] as? String)?.pluginTrimmed.lowercased() ?? "window"
        if kind == "credits" {
            var cap = jsonDouble(raw["cap"])
            if let value = cap, !value.isFinite || value <= 0 { cap = nil }
            let rawUnit = (raw["unit"] as? String)?.pluginTrimmed
            let unit = rawUnit?.isEmpty == false ? rawUnit! : defaultCreditsUnit
            // Spend and balance are the two ways an API reports money. `used` is what was spent;
            // `remaining` is what is left, which only becomes a spend once a cap says of what.
            let used: Double
            let resolvedKind: SessionKind
            if let spent = jsonDouble(raw["used"]), spent.isFinite {
                used = spent
                resolvedKind = .credits(used: spent, cap: cap, unit: unit)
            } else if let remaining = jsonDouble(raw["remaining"]), remaining.isFinite {
                if let cap {
                    used = max(cap - remaining, 0)
                    resolvedKind = .credits(used: used, cap: cap, unit: unit)
                } else {
                    used = 0
                    resolvedKind = .balance(remaining: remaining, unit: unit)
                }
            } else {
                continue
            }
            append(UsageSession(
                id: id,
                name: name?.isEmpty == false ? name! : id,
                resetText: resetText,
                usedPercent: cap.map { min(max(used / $0 * 100, 0), 100) } ?? 0,
                kind: resolvedKind
            ))
        } else {
            guard let percent = pluginUsedPercent(raw) else { continue }
            append(UsageSession(
                id: id,
                name: name?.isEmpty == false ? name! : id,
                resetText: resetText,
                usedPercent: percent
            ))
        }
    }
    let reported = (root["error"] as? String)?.pluginTrimmed
    return (sessions, reported?.isEmpty == false ? reported : nil)
}

/// Mode B: pull each mapped path out of the response and write the normalized shape, which the
/// parser above then turns into rows.
func pluginNormalizedPayload(
    from root: Any?,
    mappings: [ProviderManifest.SessionMapping]
) -> [String: Any] {
    var out: [[String: Any]] = []
    for mapping in mappings {
        let kind = mapping.kind?.pluginTrimmed.lowercased() ?? "window"
        var session: [String: Any] = ["id": mapping.id, "kind": kind]
        if let name = mapping.name, !name.pluginTrimmed.isEmpty {
            session["name"] = name
        }
        if kind == "credits" {
            if let path = mapping.used, let used = jsonDouble(jsonPathValue(root, path: path)) {
                session["used"] = used
            } else if let path = mapping.remaining,
                      let remaining = jsonDouble(jsonPathValue(root, path: path)) {
                session["remaining"] = remaining
            } else {
                continue
            }
            if let path = mapping.cap, let cap = jsonDouble(jsonPathValue(root, path: path)) {
                session["cap"] = cap
            }
            session["unit"] = mapping.unit?.pluginTrimmed.isEmpty == false
                ? mapping.unit!
                : defaultCreditsUnit
        } else {
            if let path = mapping.usedPercent,
               let percent = jsonDouble(jsonPathValue(root, path: path)) {
                session["usedPercent"] = percent
            } else if let path = mapping.remainingPercent,
                      let percent = jsonDouble(jsonPathValue(root, path: path)) {
                session["remainingPercent"] = percent
            } else {
                continue
            }
        }
        if let path = mapping.resetsAt, let iso = jsonPathValue(root, path: path) as? String {
            session["resetsAt"] = iso
        }
        out.append(session)
    }
    return ["sessions": out]
}

// MARK: - Token

enum PluginToken {
    /// Reads the token from whichever source the manifest names. The value is returned to the
    /// caller and goes straight into the request; it is never printed or stored.
    ///
    /// A `command` source runs through `/bin/sh`, the same way `ClaudeAuth` shells out to
    /// `/usr/bin/security`: calling the keychain API from this binary would prompt for the login
    /// password on every rebuild, because an ad-hoc signature is no stable identity.
    static func resolve(_ spec: ProviderManifest.TokenSpec, folder: URL) throws -> String {
        let raw: Data
        if let name = spec.env?.pluginTrimmed, !name.isEmpty {
            guard let value = ProcessInfo.processInfo.environment[name],
                  !value.pluginTrimmed.isEmpty else {
                throw PluginError.missingToken
            }
            raw = Data(value.utf8)
        } else if let file = spec.file?.pluginTrimmed, !file.isEmpty {
            let url = expandPluginPath(file, relativeTo: folder)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PluginError.missingToken
            }
            guard let data = try? Data(contentsOf: url) else {
                throw PluginError.unreadableToken
            }
            raw = data
        } else if let command = spec.command?.pluginTrimmed, !command.isEmpty {
            guard let data = PluginCommand.run(command, in: folder, timeout: 20) else {
                throw PluginError.missingToken
            }
            raw = data
        } else {
            throw PluginError.malformedManifest
        }

        guard let path = spec.path?.pluginTrimmed, !path.isEmpty else {
            guard let text = String(data: raw, encoding: .utf8)?.pluginTrimmed, !text.isEmpty else {
                throw PluginError.missingToken
            }
            return text
        }
        guard let root = try? JSONSerialization.jsonObject(with: raw) else {
            throw PluginError.unreadableToken
        }
        guard let value = jsonPathValue(root, path: path) as? String,
              !value.pluginTrimmed.isEmpty else {
            throw PluginError.missingToken
        }
        return value.pluginTrimmed
    }
}

/// `~/…` against the home directory, a bare relative path against the provider's own folder.
func expandPluginPath(_ path: String, relativeTo folder: URL) -> URL {
    let trimmed = path.pluginTrimmed
    if trimmed.hasPrefix("~") {
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }
    if trimmed.hasPrefix("/") {
        return URL(fileURLWithPath: trimmed)
    }
    return folder.appendingPathComponent(trimmed)
}

// MARK: - Command runner

enum PluginCommand {
    /// Runs a provider command and returns its stdout, or `nil` if it failed, timed out or wrote
    /// nothing. stderr goes nowhere: a script's diagnostics are its own business, and piping them
    /// into the app risks spilling whatever it echoed.
    static func run(_ command: String, in folder: URL, timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(for: command, in: folder)
        process.currentDirectoryURL = folder
        process.environment = environment()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain the pipe on another thread: a script that outruns the 64K buffer would otherwise
        // block on its own write while we sit in waitUntilExit.
        let box = ReadBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let data = box.data, !data.isEmpty else {
            return nil
        }
        return data
    }

    /// `./fetch.sh`, an absolute path, or a shell string. A single path that exists runs directly
    /// as `$0` so a filename with spaces needs no quoting; anything else is a shell string.
    private static func arguments(for command: String, in folder: URL) -> [String] {
        let trimmed = command.pluginTrimmed
        let candidate = expandPluginPath(trimmed, relativeTo: folder)
        if !trimmed.contains(" "), FileManager.default.fileExists(atPath: candidate.path) {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return ["-c", "exec \"$0\"", candidate.path]
            }
            // Not marked executable: still runnable, just not by itself.
            return ["-c", "exec /bin/sh \"$0\"", candidate.path]
        }
        return ["-c", trimmed]
    }

    /// The parent environment, so a script can read `$OPENAI_ADMIN_KEY` and friends, with `HOME`
    /// and `PATH` guaranteed. A GUI app launched from Finder inherits a bare `PATH`, so the usual
    /// places a user keeps `jq` are appended.
    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if env["HOME"]?.isEmpty ?? true {
            env["HOME"] = NSHomeDirectory()
        }
        var path = env["PATH"] ?? ""
        if path.isEmpty {
            path = "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !path.contains(extra) {
            path += ":\(extra)"
        }
        env["PATH"] = path
        return env
    }

    private final class ReadBox: @unchecked Sendable {
        var data: Data?
    }
}

// MARK: - Provider

final class PluginProvider: AgentSource, Sendable {
    let id: String
    let folder: URL
    let manifest: ProviderManifest

    var name: String { manifest.name }

    /// The SVG the manifest names, if it is really there. A missing file just means the fallback
    /// symbol, not a broken provider.
    var iconURL: URL? {
        guard let icon = manifest.icon?.pluginTrimmed, !icon.isEmpty else { return nil }
        let url = expandPluginPath(icon, relativeTo: folder)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `nil` when the folder is not a provider: no `provider.json`, unreadable, or a manifest
    /// that names neither a command nor a request. A half-written folder is ignored, not surfaced
    /// as a broken agent.
    init?(folder: URL) {
        let manifestURL = folder.appendingPathComponent("provider.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? ProviderManifest.decode(data) else {
            return nil
        }
        let id = folder.lastPathComponent
        guard !id.isEmpty, !id.hasPrefix(".") else { return nil }
        self.id = id
        self.folder = folder
        self.manifest = manifest
    }

    func load() async -> UsageAgent {
        do {
            let data = try await payload()
            let parsed = try parsePluginSessions(data)
            guard !parsed.sessions.isEmpty else {
                return failed(parsed.error ?? "Couldn't read usage")
            }
            return UsageAgent(id: id, name: name, sessions: parsed.sessions, unavailableReason: nil)
        } catch let error as PluginError {
            return failed(reason(for: error))
        } catch {
            return failed("Couldn't reach \(name)")
        }
    }

    private func payload() async throws -> Data {
        switch manifest.mode {
        case let .command(command):
            guard let data = await runCommand(command) else {
                throw PluginError.commandFailed
            }
            return data
        case let .request(spec, mappings):
            let response = try await fetch(spec)
            guard let root = try? JSONSerialization.jsonObject(with: response) else {
                throw PluginError.badPayload
            }
            let normalized = pluginNormalizedPayload(from: root, mappings: mappings)
            guard let data = try? JSONSerialization.data(withJSONObject: normalized) else {
                throw PluginError.badPayload
            }
            return data
        case nil:
            throw PluginError.malformedManifest
        }
    }

    private func runCommand(_ command: String) async -> Data? {
        let folder = folder
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: PluginCommand.run(command, in: folder, timeout: 20))
            }
        }
    }

    private func fetch(_ spec: ProviderManifest.RequestSpec) async throws -> Data {
        var urlString = spec.url
        var headers = spec.headers ?? [:]
        let needsToken = urlString.contains(pluginTokenPlaceholder)
            || headers.values.contains { $0.contains(pluginTokenPlaceholder) }
        if needsToken {
            guard let tokenSpec = manifest.token else { throw PluginError.malformedManifest }
            let token = try PluginToken.resolve(tokenSpec, folder: folder)
            urlString = substitutePluginToken(in: urlString, token: token)
            headers = headers.mapValues { substitutePluginToken(in: $0, token: token) }
        }
        guard let url = URL(string: urlString) else { throw PluginError.network }
        var request = URLRequest(url: url)
        request.httpMethod = (spec.method?.pluginTrimmed.isEmpty == false ? spec.method! : "GET")
            .uppercased()
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PluginError.network
        }
        guard let http = response as? HTTPURLResponse else { throw PluginError.network }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PluginError.signInExpired
        }
        if http.statusCode != 200 {
            throw PluginError.network
        }
        return data
    }

    private func reason(for error: PluginError) -> String {
        switch error {
        case .malformedManifest: return "provider.json is incomplete"
        case .missingToken: return "Not signed in"
        case .unreadableToken: return "Couldn't read sign-in"
        case .commandFailed: return "\(name) script failed"
        case .badPayload: return "Couldn't read usage"
        case .signInExpired: return "Sign-in expired"
        case .network: return "Couldn't reach \(name)"
        }
    }

    private func failed(_ reason: String) -> UsageAgent {
        UsageAgent(id: id, name: name, sessions: [], unavailableReason: reason)
    }
}

// MARK: - Discovery

/// What the UI needs to draw a plugin outside a refresh: its name, its icon, its tint.
struct ProviderChrome: Equatable, Sendable {
    var name: String
    var iconURL: URL?
    var color: String?
}

enum ProviderCatalog {
    static func directoryURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["AGENT_USAGE_HOME"],
           !home.pluginTrimmed.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("providers", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("agent-usage", isDirectory: true)
            .appendingPathComponent("providers", isDirectory: true)
    }

    /// Every provider folder, in folder-name order. Called on each refresh, so a folder added
    /// while the app is running is picked up without a restart.
    @discardableResult
    static func scan(in directory: URL = directoryURL()) -> [PluginProvider] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let providers = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { PluginProvider(folder: $0) }
        var chrome: [String: ProviderChrome] = [:]
        for provider in providers {
            chrome[provider.id] = ProviderChrome(
                name: provider.name,
                iconURL: provider.iconURL,
                color: provider.manifest.color
            )
        }
        store.replace(chrome)
        return providers
    }

    static func chrome(for id: String) -> ProviderChrome? {
        store.chrome(for: id)
    }

    /// Display names from the last scan, so the settings list and the menu can name a plugin
    /// without re-reading its manifest.
    static var names: [String: String] {
        store.all().mapValues(\.name)
    }

    private static let store = ChromeStore()

    private final class ChromeStore: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: ProviderChrome] = [:]

        func replace(_ next: [String: ProviderChrome]) {
            lock.lock()
            values = next
            lock.unlock()
        }

        func chrome(for id: String) -> ProviderChrome? {
            lock.lock()
            defer { lock.unlock() }
            return values[id]
        }

        func all() -> [String: ProviderChrome] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }
}

extension String {
    var pluginTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Normalised sessions may carry either `usedPercent` or `remainingPercent`; the model
/// always stores used, so a remaining figure is inverted here.
func pluginUsedPercent(_ raw: [String: Any]) -> Double? {
    if let used = jsonDouble(raw["usedPercent"]), used.isFinite {
        return min(max(used, 0), 100)
    }
    if let remaining = jsonDouble(raw["remainingPercent"]), remaining.isFinite {
        return min(max(100 - remaining, 0), 100)
    }
    return nil
}
