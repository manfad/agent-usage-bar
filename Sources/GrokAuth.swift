import Foundation

enum GrokAuth {
    private static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    private static let refreshLead: TimeInterval = 5 * 60

    static func authFileURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["GROK_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    static func accessToken(forceRefresh: Bool) async throws -> String {
        let material = try loadMaterial()
        let expiresSoon: Bool
        if let expiresAt = material.expiresAt {
            expiresSoon = expiresAt.timeIntervalSinceNow <= refreshLead
        } else {
            expiresSoon = true
        }
        let needsRefresh = forceRefresh || material.accessKey.isEmpty || expiresSoon
        if !needsRefresh {
            return material.accessKey
        }
        if material.refreshToken.isEmpty {
            if !forceRefresh && !material.accessKey.isEmpty {
                return material.accessKey
            }
            throw GrokLoadError.signInExpired
        }
        do {
            let tokens = try await requestRefresh(
                refreshToken: material.refreshToken,
                clientID: material.clientID
            )
            var entry = material.entry
            entry["key"] = tokens.access
            if let refresh = tokens.refresh, !refresh.isEmpty {
                entry["refresh_token"] = refresh
            }
            entry["expires_at"] = iso8601(tokens.expiresAt)
            var root = material.root
            root[material.storageKey] = entry
            try? writeRoot(root, to: material.url)
            return tokens.access
        } catch let error as GrokLoadError {
            let unexpired = (material.expiresAt?.timeIntervalSinceNow ?? 0) > 0
            if !forceRefresh && !material.accessKey.isEmpty && (unexpired || error == .network) {
                return material.accessKey
            }
            throw error
        } catch {
            if !forceRefresh && !material.accessKey.isEmpty {
                return material.accessKey
            }
            throw GrokLoadError.network
        }
    }

    private struct Material {
        var url: URL
        var root: [String: Any]
        var storageKey: String
        var entry: [String: Any]
        var accessKey: String
        var refreshToken: String
        var expiresAt: Date?
        var clientID: String
    }

    private static func loadMaterial() throws -> Material {
        let url = authFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GrokLoadError.notSignedIn
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GrokLoadError.unreadableSignIn
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokLoadError.unreadableSignIn
        }
        guard let picked = pickEntry(root) else {
            throw GrokLoadError.notSignedIn
        }
        let entry = picked.entry
        return Material(
            url: url,
            root: root,
            storageKey: picked.storageKey,
            entry: entry,
            accessKey: entry["key"] as? String ?? "",
            refreshToken: entry["refresh_token"] as? String ?? "",
            expiresAt: (entry["expires_at"] as? String).flatMap(parseISO8601),
            clientID: clientID(storageKey: picked.storageKey, entry: entry)
        )
    }

    private static func pickEntry(_ root: [String: Any]) -> (storageKey: String, entry: [String: Any])? {
        struct Candidate {
            var storageKey: String
            var entry: [String: Any]
            var rank: Int
        }
        var candidates: [Candidate] = []
        for (storageKey, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            let accessKey = entry["key"] as? String ?? ""
            let refresh = entry["refresh_token"] as? String ?? ""
            guard !accessKey.isEmpty || !refresh.isEmpty else { continue }
            let issuer = entry["oidc_issuer"] as? String ?? ""
            let scope = entry["scope"] as? String ?? ""
            let mode = entry["auth_mode"] as? String ?? ""
            let mentionsAuth = storageKey.contains("auth.x.ai")
                || issuer.contains("auth.x.ai")
                || scope.contains("auth.x.ai")
            let oidc = mode == "oidc"
            let rank: Int
            if mentionsAuth && oidc {
                rank = 0
            } else if mentionsAuth {
                rank = 1
            } else if oidc {
                rank = 2
            } else {
                rank = 3
            }
            candidates.append(Candidate(storageKey: storageKey, entry: entry, rank: rank))
        }
        candidates.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.storageKey < rhs.storageKey
        }
        return candidates.first.map { ($0.storageKey, $0.entry) }
    }

    private static func clientID(storageKey: String, entry: [String: Any]) -> String {
        if let id = entry["oidc_client_id"] as? String, !id.isEmpty {
            return id
        }
        if let range = storageKey.range(of: "::") {
            let suffix = String(storageKey[range.upperBound...])
            if !suffix.isEmpty { return suffix }
        }
        return defaultClientID
    }

    private static func requestRefresh(refreshToken: String, clientID: String) async throws -> (access: String, refresh: String?, expiresAt: Date) {
        guard let url = URL(string: "https://auth.x.ai/oauth2/token") else {
            throw GrokLoadError.network
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ])
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
        if http.statusCode != 200 {
            if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
                throw GrokLoadError.signInExpired
            }
            throw GrokLoadError.network
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String,
              !access.isEmpty else {
            throw GrokLoadError.signInExpired
        }
        let expiresIn = jsonDouble(object["expires_in"]) ?? 3600
        let refresh = object["refresh_token"] as? String
        return (access, refresh, Date().addingTimeInterval(expiresIn))
    }

    private static func writeRoot(_ root: [String: Any], to url: URL) throws {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        if #available(macOS 10.15, *) {
            options.insert(.withoutEscapingSlashes)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: options)
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        // .atomic swaps the inode, so put the previous mode back on a private auth file.
        try data.write(to: url, options: .atomic)
        if let mode {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
    }

    private static func formBody(_ fields: [(String, String)]) -> Data {
        let encoded = fields.map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
