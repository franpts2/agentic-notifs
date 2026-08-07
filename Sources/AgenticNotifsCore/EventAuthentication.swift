import Foundation

public enum EventAuthentication {
    public static let tokenLength = 64

    public static func loadToken(home: URL? = nil) throws -> String {
        let url = tokenURL(home: home)
        try rejectSymbolicLink(at: url)

        guard let data = FileManager.default.contents(atPath: url.path),
              let value = String(data: data, encoding: .utf8)
        else {
            throw EventAuthenticationError.missingToken
        }

        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(token) else {
            throw EventAuthenticationError.invalidToken
        }
        return token
    }

    @discardableResult
    public static func ensureToken(home: URL? = nil) throws -> String {
        let url = tokenURL(home: home)
        if FileManager.default.fileExists(atPath: url.path) {
            let token = try loadToken(home: home)
            try setPrivatePermissions(on: url)
            return token
        }

        try rejectSymbolicLink(at: url)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let token = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        try Data("\(token)\n".utf8).write(to: url, options: .atomic)
        try setPrivatePermissions(on: url)
        return token
    }

    public static func tokenURL(home: URL? = nil) -> URL {
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/Agentic Notifs", isDirectory: true)
            .appendingPathComponent("event-token")
    }

    private static func isValid(_ token: String) -> Bool {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        return token.count == tokenLength
            && token.unicodeScalars.allSatisfy(hexadecimal.contains)
    }

    private static func rejectSymbolicLink(at url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw EventAuthenticationError.symbolicLink
        }
    }

    private static func setPrivatePermissions(on url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum EventAuthenticationError: LocalizedError {
    case missingToken
    case invalidToken
    case symbolicLink

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "event authentication is not configured; run Scripts/install.sh"
        case .invalidToken:
            "the Agentic Notifs event token is invalid; reinstall Agentic Notifs"
        case .symbolicLink:
            "refusing to use a symlinked Agentic Notifs event token"
        }
    }
}
