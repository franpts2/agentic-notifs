import Foundation

public enum AgentName: String, CaseIterable, Sendable {
    case opencode
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .opencode: "OpenCode"
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

public enum AgentHostApp: String, CaseIterable, Sendable {
    case ghostty
    case zed
}

public enum AgentEventKind: String, CaseIterable, Sendable {
    case running
    case done
    case input
    case permission
    case error
    case metadata
    case stopped

    public var title: String {
        switch self {
        case .running: "Running"
        case .done: "Finished"
        case .input: "Question"
        case .permission: "Needs permission"
        case .error: "Stopped with an error"
        case .metadata: "Session updated"
        case .stopped: "Session ended"
        }
    }

    public var defaultMessage: String {
        switch self {
        case .running: "The agent is working."
        case .done: "The agent finished its turn."
        case .input: "The agent is waiting for your answer."
        case .permission: "The agent is waiting for an approval."
        case .error: "The agent encountered an error."
        case .metadata: "The session details changed."
        case .stopped: "The agent session ended."
        }
    }

    public var presentsNotification: Bool {
        switch self {
        case .running, .metadata, .stopped: false
        case .done, .input, .permission, .error: true
        }
    }
}

public struct AgentEvent: Equatable, Sendable {
    public static let scheme = "agentic-notifs"
    public static let host = "emit"
    public static let bundleIdentifier = "dev.agenticnotifs.app"

    private static let maximumURLLength = 8_192
    private static let maximumPathLength = 4_096
    private static let maximumProjectNameLength = 160
    private static let maximumSessionIDLength = 200
    private static let maximumSessionNameLength = 160
    private static let maximumMessageLength = 240

    public let agent: AgentName
    public let kind: AgentEventKind
    public let projectPath: String
    public let projectName: String
    public let sessionID: String?
    public let sessionName: String?
    public let hostApp: AgentHostApp?
    public let message: String?

    public init(
        agent: AgentName,
        kind: AgentEventKind,
        projectPath: String,
        projectName: String? = nil,
        sessionID: String? = nil,
        sessionName: String? = nil,
        hostApp: AgentHostApp? = nil,
        message: String? = nil
    ) {
        let expandedPath = NSString(string: projectPath).expandingTildeInPath
        let normalizedPath = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
        let fallbackName = URL(fileURLWithPath: normalizedPath).lastPathComponent

        self.agent = agent
        self.kind = kind
        self.projectPath = normalizedPath
        let derivedName = fallbackName.isEmpty ? normalizedPath : fallbackName

        self.projectName = Self.nonEmpty(projectName, limitedTo: Self.maximumProjectNameLength)
            ?? String(derivedName.prefix(Self.maximumProjectNameLength))
        self.sessionID = Self.nonEmpty(sessionID, limitedTo: Self.maximumSessionIDLength)
        self.sessionName = Self.nonEmpty(sessionName, limitedTo: Self.maximumSessionNameLength)
        self.hostApp = hostApp
        self.message = Self.nonEmpty(message, limitedTo: Self.maximumMessageLength)
    }

    public func url(authenticationToken: String) -> URL? {
        guard authenticationToken.count == EventAuthentication.tokenLength else {
            return nil
        }

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "token", value: authenticationToken),
            URLQueryItem(name: "agent", value: agent.rawValue),
            URLQueryItem(name: "event", value: kind.rawValue),
            URLQueryItem(name: "projectPath", value: projectPath),
            URLQueryItem(name: "projectName", value: projectName),
            URLQueryItem(name: "sessionID", value: sessionID),
            URLQueryItem(name: "sessionName", value: sessionName),
            URLQueryItem(name: "hostApp", value: hostApp?.rawValue),
            URLQueryItem(name: "message", value: message)
        ].filter { $0.value != nil }
        guard let url = components.url,
              url.absoluteString.utf8.count <= Self.maximumURLLength
        else {
            return nil
        }
        return url
    }

    public init?(url: URL, authenticationToken: String) {
        guard authenticationToken.count == EventAuthentication.tokenLength else {
            return nil
        }

        guard url.absoluteString.utf8.count <= Self.maximumURLLength,
              url.scheme == Self.scheme,
              url.host == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.isEmpty,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil
        else {
            return nil
        }

        let allowedNames = Set([
            "token", "agent", "event", "projectPath", "projectName", "sessionID", "sessionName", "hostApp",
            "message"
        ])
        let items = components.queryItems ?? []
        let names = items.map(\.name)
        guard names.allSatisfy(allowedNames.contains),
              names.count == Set(names).count
        else {
            return nil
        }
        let values = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        let hostApp = values["hostApp"].flatMap(AgentHostApp.init(rawValue:))

        guard values["token"] == authenticationToken,
              let agentValue = values["agent"],
              let agent = AgentName(rawValue: agentValue),
              let eventValue = values["event"],
              let kind = AgentEventKind(rawValue: eventValue),
              let projectPath = values["projectPath"],
              projectPath.hasPrefix("/"),
              projectPath.utf8.count <= Self.maximumPathLength,
              Self.isWithinLimit(values["projectName"], Self.maximumProjectNameLength),
              Self.isWithinLimit(values["sessionID"], Self.maximumSessionIDLength),
              Self.isWithinLimit(values["sessionName"], Self.maximumSessionNameLength),
              values["hostApp"] == nil || hostApp != nil,
              Self.isWithinLimit(values["message"], Self.maximumMessageLength)
        else {
            return nil
        }

        self.init(
            agent: agent,
            kind: kind,
            projectPath: projectPath,
            projectName: values["projectName"],
            sessionID: values["sessionID"],
            sessionName: values["sessionName"],
            hostApp: hostApp,
            message: values["message"]
        )
    }

    private static func nonEmpty(_ value: String?, limitedTo limit: Int) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return String(trimmed.prefix(limit))
    }

    private static func isWithinLimit(_ value: String?, _ limit: Int) -> Bool {
        value.map { $0.count <= limit } ?? true
    }
}
