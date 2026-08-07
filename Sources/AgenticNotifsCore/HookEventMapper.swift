import Foundation

public enum HookEventMapper {
    public static func event(
        agent: AgentName,
        hookName: String,
        payload: [String: Any],
        fallbackDirectory: String
    ) -> AgentEvent? {
        guard string(payload["agent_id"]) == nil else {
            return nil
        }

        let kind: AgentEventKind?

        switch agent {
        case .claude:
            kind = claudeKind(hookName: hookName, payload: payload)
        case .codex:
            kind = codexKind(hookName: hookName)
        case .opencode:
            kind = AgentEventKind(rawValue: hookName)
        }

        guard let kind else {
            return nil
        }

        let cwd = string(payload["cwd"]) ?? fallbackDirectory
        let sessionID = string(payload["session_id"])
            ?? string(payload["sessionID"])
            ?? string(payload["conversation_id"])
        let sessionName = string(payload["session_name"])
            ?? string(payload["session_title"])
            ?? string(payload["conversation_name"])

        return AgentEvent(
            agent: agent,
            kind: kind,
            projectPath: cwd,
            sessionID: sessionID,
            sessionName: sessionName
        )
    }

    private static func claudeKind(hookName: String, payload: [String: Any]) -> AgentEventKind? {
        switch hookName.lowercased() {
        case "userpromptsubmit", "user-prompt-submit":
            return .running
        case "posttooluse", "post-tool-use", "posttoolusefailure", "post-tool-use-failure":
            return .running
        case "permissionrequest", "permission-request":
            return .permission
        case "stop":
            return hasActiveBackgroundWork(payload) ? .running : .done
        case "stopfailure", "stop-failure", "error":
            return .error
        case "sessionend", "session-end":
            return .stopped
        case "notification":
            switch string(payload["notification_type"])?.lowercased() {
            case "permission_prompt":
                return .permission
            case "idle_prompt", "agent_needs_input", "elicitation_dialog":
                return .input
            case "agent_completed":
                return .done
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func codexKind(hookName: String) -> AgentEventKind? {
        switch hookName.lowercased() {
        case "userpromptsubmit", "user-prompt-submit":
            return .running
        case "posttooluse", "post-tool-use":
            return .running
        case "stop", "notify":
            return .done
        case "permissionrequest", "permission-request":
            return .permission
        case "error":
            return .error
        case "sessionend", "session-end":
            return .stopped
        default:
            return nil
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return value
    }

    private static func hasActiveBackgroundWork(_ payload: [String: Any]) -> Bool {
        [payload["background_tasks"], payload["session_crons"]].contains { value in
            if let values = value as? [Any] {
                return !values.isEmpty
            }
            if let values = value as? [String: Any] {
                return !values.isEmpty
            }
            return false
        }
    }
}
