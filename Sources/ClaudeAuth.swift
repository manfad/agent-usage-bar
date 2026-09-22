import Foundation

enum ClaudeLoadError: Error, Equatable {
    case notSignedIn
    case signInExpired
    case unreadableSignIn
    case badPayload
    case network
}

struct ClaudeCredentials: Equatable {
    var accessToken: String
    var expiresAt: Date?
    var subscriptionType: String?
}

enum ClaudeAuth {
    /// Generic-password service Claude Code writes its OAuth blob under. The account is the
    /// macOS user name, so we match on the service alone.
    static let keychainService = "Claude Code-credentials"

    static func credentialsFileURL() -> URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent(".credentials.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json")
    }

    /// File first, keychain second. Both reads are read-only; nothing here ever writes a
    /// credential back.
    static func credentials(now: Date = Date()) throws -> ClaudeCredentials {
        if let data = fileData() {
            return try validated(parseCredentials(data), now: now)
        }
        guard let data = keychainData() else {
            throw ClaudeLoadError.notSignedIn
        }
        return try validated(parseCredentials(data), now: now)
    }

    static func parseCredentials(_ data: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw ClaudeLoadError.unreadableSignIn
        }
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ClaudeLoadError.notSignedIn
        }
        var expiresAt: Date?
        if let millis = jsonDouble(oauth["expiresAt"]), millis > 0 {
            expiresAt = Date(timeIntervalSince1970: millis / 1000)
        }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    /// We never refresh: Claude Code renews its own token every time it runs, so an expired
    /// token is a prompt to run `claude`, not something to fix behind the user's back.
    static func validated(_ credentials: ClaudeCredentials, now: Date = Date()) throws -> ClaudeCredentials {
        if let expiresAt = credentials.expiresAt, expiresAt <= now {
            throw ClaudeLoadError.signInExpired
        }
        return credentials
    }

    private static func fileData() -> Data? {
        let url = credentialsFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Reads the item through `/usr/bin/security`, which Claude Code used to write it and is
    /// therefore already on the item's ACL. Calling SecItemCopyMatching from this binary instead
    /// makes macOS ask for the login password on every rebuild, because an ad-hoc signature gives
    /// the keychain no stable identity to trust.
    private static func keychainData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let box = ReadBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        if finished.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let data = box.data else { return nil }

        // `-w` prints the password followed by a newline.
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Data(trimmed.utf8)
    }

    private final class ReadBox: @unchecked Sendable {
        var data: Data?
    }
}
