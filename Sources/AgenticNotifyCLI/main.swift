import AgenticNotifsCore
import Foundation

@main
enum AgenticNotifyCLI {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("agentic-notify: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            throw CLIError.usage
        }

        switch command {
        case "emit":
            try emit(arguments: Array(arguments.dropFirst()))
        case "claude-hook":
            try handleHook(agent: .claude, arguments: Array(arguments.dropFirst()))
        case "codex-hook":
            try handleHook(agent: .codex, arguments: Array(arguments.dropFirst()))
        case "install-adapters":
            try AdapterInstaller.install(arguments: Array(arguments.dropFirst()))
        case "self-test":
            try selfTest()
        case "help", "--help", "-h":
            print(CLIError.help)
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func emit(arguments: [String]) throws {
        let options = try parseOptions(arguments)
        guard let agentValue = options["agent"],
              let agent = AgentName(rawValue: agentValue),
              let eventValue = options["event"],
              let event = AgentEventKind(rawValue: eventValue),
              let projectPath = options["project-path"]
        else {
            throw CLIError.invalidArguments("emit requires --agent, --event, and --project-path")
        }
        let hostApp: AgentHostApp?
        if let value = options["host-app"] {
            guard let parsedHostApp = AgentHostApp(rawValue: value) else {
                throw CLIError.invalidArguments("--host-app must be ghostty or zed")
            }
            hostApp = parsedHostApp
        } else {
            hostApp = nil
        }

        try send(AgentEvent(
            agent: agent,
            kind: event,
            projectPath: projectPath,
            projectName: options["project-name"],
            sessionID: options["session-id"],
            sessionName: options["session-name"],
            hostApp: hostApp,
            message: options["message"]
        ))
    }

    private static func handleHook(agent: AgentName, arguments: [String]) throws {
        guard let hookName = arguments.first else {
            throw CLIError.invalidArguments("hook name is required")
        }

        let data = FileHandle.standardInput.readDataToEndOfFile()
        let payload: [String: Any]
        if data.isEmpty {
            payload = [:]
        } else {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError.invalidArguments("hook input must be a JSON object")
            }
            payload = object
        }

        guard let event = HookEventMapper.event(
            agent: agent,
            hookName: hookName,
            payload: payload,
            fallbackDirectory: FileManager.default.currentDirectoryPath
        ) else {
            return
        }
        try send(event)
    }

    private static func send(_ event: AgentEvent) throws {
        let token = try EventAuthentication.loadToken()
        let event = AgentEvent(
            agent: event.agent,
            kind: event.kind,
            projectPath: event.projectPath,
            projectName: event.projectName,
            sessionID: event.sessionID,
            sessionName: event.sessionName,
            hostApp: event.hostApp ?? detectedHostApp(),
            message: event.message
        )
        guard let url = event.url(authenticationToken: token) else {
            throw CLIError.invalidArguments("event could not be encoded")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-b", AgentEvent.bundleIdentifier, url.absoluteString]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError.deliveryFailed
        }
    }

    private static func selfTest() throws {
        let token = String(repeating: "a", count: EventAuthentication.tokenLength)
        let original = AgentEvent(
            agent: .opencode,
            kind: .permission,
            projectPath: "/tmp/a project",
            projectName: "A project",
            sessionID: "session/1",
            sessionName: "Fix notifications",
            hostApp: .ghostty,
            message: "Approval required"
        )
        guard let url = original.url(authenticationToken: token),
              AgentEvent(url: url, authenticationToken: token) == original
        else {
            throw CLIError.selfTestFailed("event URL round-trip")
        }

        let claude = HookEventMapper.event(
            agent: .claude,
            hookName: "notification",
            payload: [
                "cwd": "/tmp/project",
                "session_id": "abc",
                "notification_type": "permission_prompt"
            ],
            fallbackDirectory: "/tmp"
        )
        guard claude?.kind == .permission,
              claude?.projectPath == "/tmp/project",
              claude?.sessionID == "abc"
        else {
            throw CLIError.selfTestFailed("Claude hook mapping")
        }

        let claudeRunning = HookEventMapper.event(
            agent: .claude,
            hookName: "userpromptsubmit",
            payload: [
                "cwd": "/tmp/project",
                "session_id": "abc",
                "session_name": "Menu polish"
            ],
            fallbackDirectory: "/tmp"
        )
        guard claudeRunning?.kind == .running,
              claudeRunning?.sessionName == "Menu polish"
        else {
            throw CLIError.selfTestFailed("Claude session-name mapping")
        }

        let claudeBackgroundWork = HookEventMapper.event(
            agent: .claude,
            hookName: "stop",
            payload: ["background_tasks": [["id": "task-1"]]],
            fallbackDirectory: "/tmp"
        )
        guard claudeBackgroundWork?.kind == .running else {
            throw CLIError.selfTestFailed("Claude background-work mapping")
        }

        let claudeSubagent = HookEventMapper.event(
            agent: .claude,
            hookName: "userpromptsubmit",
            payload: ["agent_id": "subagent-1", "cwd": "/tmp/project"],
            fallbackDirectory: "/tmp"
        )
        guard claudeSubagent == nil else {
            throw CLIError.selfTestFailed("subagent filtering")
        }

        let codex = HookEventMapper.event(
            agent: .codex,
            hookName: "stop",
            payload: ["cwd": "/tmp/project"],
            fallbackDirectory: "/tmp"
        )
        guard codex?.kind == .done else {
            throw CLIError.selfTestFailed("Codex hook mapping")
        }

        let codexStopped = HookEventMapper.event(
            agent: .codex,
            hookName: "sessionend",
            payload: ["cwd": "/tmp/project"],
            fallbackDirectory: "/tmp"
        )
        guard codexStopped?.kind == .stopped else {
            throw CLIError.selfTestFailed("Codex stopped-state mapping")
        }

        let ignoredClaudeNotification = HookEventMapper.event(
            agent: .claude,
            hookName: "notification",
            payload: ["notification_type": "auth_success"],
            fallbackDirectory: "/tmp"
        )
        guard ignoredClaudeNotification == nil else {
            throw CLIError.selfTestFailed("non-actionable Claude notification filtering")
        }

        guard let duplicateURL = URL(string: "agentic-notifs://emit?token=\(token)&agent=codex&agent=claude&event=done&projectPath=/tmp"),
              AgentEvent(url: duplicateURL, authenticationToken: token) == nil
        else {
            throw CLIError.selfTestFailed("duplicate URL parameter rejection")
        }

        guard AgentEvent(url: url, authenticationToken: String(repeating: "b", count: token.count)) == nil else {
            throw CLIError.selfTestFailed("event authentication")
        }

        guard detectedHostApp(environment: ["TERM_PROGRAM": "ghostty"]) == .ghostty,
              detectedHostApp(environment: ["TERM_PROGRAM": "zed"]) == .zed
        else {
            throw CLIError.selfTestFailed("terminal host detection")
        }

        guard !AgentEventKind.running.presentsNotification,
              AgentEventKind.done.presentsNotification,
              !AgentEventKind.stopped.presentsNotification
        else {
            throw CLIError.selfTestFailed("activity-only event filtering")
        }

        print("All self-tests passed.")
    }

    private static func detectedHostApp(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AgentHostApp? {
        let values = [
            environment["TERM_PROGRAM"],
            environment["LC_TERMINAL"],
            environment["TERMINAL_EMULATOR"]
        ].compactMap { $0?.lowercased() }
        if environment["GHOSTTY_RESOURCES_DIR"] != nil || values.contains(where: { $0.contains("ghostty") }) {
            return .ghostty
        }
        if values.contains(where: { $0.contains("zed") }) {
            return .zed
        }
        return nil
    }

    private static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--"), index + 1 < arguments.count else {
                throw CLIError.invalidArguments("expected --name value pairs")
            }
            options[String(argument.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        return options
    }
}

private enum AdapterInstaller {
    static func install(arguments: [String]) throws {
        let options = try parseOptions(arguments)
        guard let pluginPath = options["opencode-plugin"] else {
            throw CLIError.invalidArguments("install-adapters requires --opencode-plugin")
        }

        let fileManager = FileManager.default
        let home = options["home"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let configRoot = options["config-root"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
                .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? home.appendingPathComponent(".config", isDirectory: true)

        let pluginSource = URL(fileURLWithPath: NSString(string: pluginPath).expandingTildeInPath)
        let pluginData = try Data(contentsOf: pluginSource)
        guard !pluginData.isEmpty else {
            throw CLIError.invalidArguments("\(pluginSource.path) is empty")
        }

        let pluginDirectory = configRoot.appendingPathComponent("opencode/plugins", isDirectory: true)
        let pluginDestination = pluginDirectory.appendingPathComponent("agentic-notifs.js")
        let claudePath = home.appendingPathComponent(".claude/settings.json")
        let codexPath = home.appendingPathComponent(".codex/hooks.json")

        let claudeSettings = try configuredClaudeHooks(at: claudePath)
        let codexSettings = try configuredCodexHooks(at: codexPath)

        try EventAuthentication.ensureToken(home: home)
        try rejectSymbolicLink(at: pluginDestination)
        try rejectSymbolicLink(at: claudePath)
        try rejectSymbolicLink(at: codexPath)

        try fileManager.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try pluginData.write(to: pluginDestination, options: .atomic)
        try writeJSONObject(claudeSettings, to: claudePath)
        try writeJSONObject(codexSettings, to: codexPath)

        print("Installed OpenCode, Claude Code, and Codex adapters.")
        print("Restart active agent sessions. In Codex, open /hooks once to trust the new hooks.")
    }

    private static func configuredClaudeHooks(at path: URL) throws -> [String: Any] {
        var root = try readJSONObject(at: path)
        var hooks = try hooksDictionary(in: root, at: path)

        try appendHook(
            event: "UserPromptSubmit",
            command: "\"$HOME/.local/bin/agentic-notify\" claude-hook userpromptsubmit",
            to: &hooks,
            matcher: nil
        )
        try appendHook(
            event: "PermissionRequest",
            command: "\"$HOME/.local/bin/agentic-notify\" claude-hook permissionrequest",
            to: &hooks,
            matcher: ""
        )
        try appendHook(
            event: "PostToolUse",
            command: "\"$HOME/.local/bin/agentic-notify\" claude-hook posttooluse",
            to: &hooks,
            matcher: ""
        )
        try appendHook(
            event: "PostToolUseFailure",
            command: "\"$HOME/.local/bin/agentic-notify\" claude-hook posttoolusefailure",
            to: &hooks,
            matcher: ""
        )
        try appendHook(
            event: "Notification",
            command: "\"$HOME/.local/bin/agentic-notify\" claude-hook notification",
            to: &hooks,
            matcher: "idle_prompt|agent_needs_input|elicitation_dialog"
        )
        try appendHook(
            event: "Stop",
            command: "\"$HOME/.local/bin/agentic-notify\" claude-hook stop",
            to: &hooks,
            matcher: ""
        )
        try appendHook(
            event: "StopFailure",
            command: "\"$HOME/.local/bin/agentic-notify\" claude-hook stopfailure",
            to: &hooks,
            matcher: ""
        )
        try appendHook(
            event: "SessionEnd",
            command: "\"$HOME/.local/bin/agentic-notify\" claude-hook sessionend",
            to: &hooks,
            matcher: ""
        )

        root["hooks"] = hooks
        return root
    }

    private static func configuredCodexHooks(at path: URL) throws -> [String: Any] {
        var root = try readJSONObject(at: path)
        root["description"] = root["description"] ?? "User-level Codex hooks"
        var hooks = try hooksDictionary(in: root, at: path)

        try appendHook(
            event: "UserPromptSubmit",
            command: "\"$HOME/.local/bin/agentic-notify\" codex-hook userpromptsubmit",
            to: &hooks,
            matcher: nil
        )
        try appendHook(
            event: "PermissionRequest",
            command: "\"$HOME/.local/bin/agentic-notify\" codex-hook permissionrequest",
            to: &hooks,
            matcher: "*"
        )
        try appendHook(
            event: "PostToolUse",
            command: "\"$HOME/.local/bin/agentic-notify\" codex-hook posttooluse",
            to: &hooks,
            matcher: "*"
        )
        try appendHook(
            event: "Stop",
            command: "\"$HOME/.local/bin/agentic-notify\" codex-hook stop",
            to: &hooks,
            matcher: nil
        )
        try appendHook(
            event: "SessionEnd",
            command: "\"$HOME/.local/bin/agentic-notify\" codex-hook sessionend",
            to: &hooks,
            matcher: nil,
            timeout: 3
        )

        root["hooks"] = hooks
        return root
    }

    private static func appendHook(
        event: String,
        command: String,
        to hooks: inout [String: Any],
        matcher: String?,
        timeout: Int = 5
    ) throws {
        let entries: [[String: Any]]
        if let value = hooks[event] {
            guard let existingEntries = value as? [[String: Any]] else {
                throw CLIError.invalidArguments("hooks.\(event) must be an array of objects")
            }
            entries = existingEntries
        } else {
            entries = []
        }

        let alreadyInstalled = try entries.contains { entry in
            let handlers = try handlers(in: entry, event: event)
            let matcherMatches = matcher.map { entry["matcher"] as? String == $0 }
                ?? (entry["matcher"] == nil)
            return matcherMatches && handlers.contains { handler in
                (handler["type"] as? String) == "command"
                    && (handler["command"] as? String) == command
                    && (handler["timeout"] as? NSNumber)?.intValue == timeout
            }
        }
        guard !alreadyInstalled else {
            return
        }

        var cleanedEntries: [[String: Any]] = []
        for var entry in entries {
            let existingHandlers = try handlers(in: entry, event: event)
            let remainingHandlers = existingHandlers.filter {
                ($0["command"] as? String) != command
            }
            if remainingHandlers.count == existingHandlers.count {
                cleanedEntries.append(entry)
            } else if !remainingHandlers.isEmpty {
                entry["hooks"] = remainingHandlers
                cleanedEntries.append(entry)
            }
        }

        var entry: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": command,
                "timeout": timeout
            ]]
        ]
        if let matcher {
            entry["matcher"] = matcher
        }
        cleanedEntries.append(entry)
        hooks[event] = cleanedEntries
    }

    private static func hooksDictionary(in root: [String: Any], at url: URL) throws -> [String: Any] {
        guard let value = root["hooks"] else {
            return [:]
        }
        guard let hooks = value as? [String: Any] else {
            throw CLIError.invalidArguments("\(url.path): hooks must be a JSON object")
        }
        return hooks
    }

    private static func handlers(in entry: [String: Any], event: String) throws -> [[String: Any]] {
        guard let handlers = entry["hooks"] as? [[String: Any]] else {
            throw CLIError.invalidArguments("hooks.\(event) entries must contain a hooks array")
        }
        return handlers
    }

    private static func readJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.invalidArguments("\(url.path) must contain a JSON object")
        }
        return object
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("agentic-notifs-backup")
            if !fileManager.fileExists(atPath: backup.path) {
                try fileManager.copyItem(at: url, to: backup)
            }
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    private static func rejectSymbolicLink(at url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw CLIError.invalidArguments("refusing to replace symbolic link at \(url.path)")
        }
    }

    private static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                throw CLIError.invalidArguments("expected --name value pairs")
            }
            result[String(arguments[index].dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        return result
    }
}

private enum CLIError: LocalizedError {
    case usage
    case unknownCommand(String)
    case invalidArguments(String)
    case deliveryFailed
    case selfTestFailed(String)

    static let help = """
    Usage:
      agentic-notify emit --agent <opencode|claude|codex> --event <running|done|input|permission|error|metadata|stopped> --project-path <path> [options]
      agentic-notify claude-hook <userpromptsubmit|permissionrequest|posttooluse|posttoolusefailure|notification|stop|stopfailure|sessionend>
      agentic-notify codex-hook <userpromptsubmit|permissionrequest|posttooluse|stop|sessionend>
      agentic-notify install-adapters --opencode-plugin <path> [--home <path>] [--config-root <path>]
      agentic-notify self-test

    Optional emit values: --project-name, --session-id, --session-name, --host-app <ghostty|zed>, --message
    """

    var errorDescription: String? {
        switch self {
        case .usage:
            Self.help
        case let .unknownCommand(command):
            "unknown command '\(command)'\n\n\(Self.help)"
        case let .invalidArguments(message):
            message
        case .deliveryFailed:
            "could not launch Agentic Notifs; run Scripts/install.sh first"
        case let .selfTestFailed(check):
            "self-test failed: \(check)"
        }
    }
}
