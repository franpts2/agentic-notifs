import AgenticNotifsCore
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

@main
enum AgenticNotifsApplication {
    @MainActor
    static func main() {
        installBundleIdentifierHook()
        let application = NSApplication.shared
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            application.applicationIconImage = icon
        }
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

private func installBundleIdentifierHook() {
    guard let original = class_getInstanceMethod(
        Bundle.self,
        #selector(getter: Bundle.bundleIdentifier)
    ), let replacement = class_getInstanceMethod(
        Bundle.self,
        #selector(Bundle.agenticBundleIdentifier)
    ) else {
        return
    }
    method_exchangeImplementations(original, replacement)
}

private extension Bundle {
    @objc dynamic func agenticBundleIdentifier() -> String? {
        self == .main ? AgentEvent.bundleIdentifier : agenticBundleIdentifier()
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var activities: [String: AgentActivity] = [:]
    private var scanMissCounts: [String: Int] = [:]
    private var scanGeneration = 0
    private var activityRevision = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSUserNotificationCenter.default.delegate = self
        installURLHandler()
        createStatusItem()
        reloadAgentStates()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(event:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc
    private func handleURL(event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: value),
              let token = try? EventAuthentication.loadToken(),
              let agentEvent = AgentEvent(url: url, authenticationToken: token)
        else {
            return
        }

        handle(agentEvent)
    }

    private func handle(_ event: AgentEvent) {
        updateActivity(with: event)
        guard event.kind.presentsNotification else {
            return
        }
        deliverNotification(event)
    }

    private func deliverNotification(_ event: AgentEvent) {
        let notification = NSUserNotification()
        notification.title = event.sessionName ?? event.projectName
        notification.informativeText = event.message ?? event.kind.defaultMessage
        notification.soundName = NSUserNotificationDefaultSoundName
        var userInfo: [String: Any] = ["projectPath": event.projectPath]
        let identity = "\(event.agent.rawValue):\(event.sessionID ?? event.projectPath)"
        let activity = activities[identity]
        if let hostApp = event.hostApp ?? activity?.hostApp {
            userInfo["hostApp"] = hostApp.rawValue
        }
        if let hostWindow = activity?.hostWindow {
            userInfo["hostProcessID"] = NSNumber(value: hostWindow.processID)
            userInfo["hostWindowID"] = NSNumber(value: hostWindow.windowID)
        }
        notification.userInfo = userInfo

        // Notification Center otherwise keeps using its placeholder identity image.
        if let icon = NSApplication.shared.applicationIconImage {
            notification.setValue(icon, forKey: "_identityImage")
            notification.setValue(false, forKey: "_identityImageHasBorder")
        }

        let sessionComponent = event.sessionID ?? UUID().uuidString
        notification.identifier = "\(event.agent.rawValue):\(sessionComponent):\(event.kind.rawValue):\(UUID().uuidString)"
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.menu = statusMenu
        statusItem = item
        refreshStatusItem()
    }

    private func updateActivity(with event: AgentEvent) {
        activityRevision += 1
        let identity = "\(event.agent.rawValue):\(event.sessionID ?? event.projectPath)"
        var previousActivity = activities[identity]
        if activities[identity] == nil,
           let detectedKey = activities.first(where: { key, activity in
            key.hasPrefix("detected:\(event.agent.rawValue):")
                && activity.projectPath == event.projectPath
        })?.key {
            previousActivity = activities.removeValue(forKey: detectedKey)
            scanMissCounts.removeValue(forKey: detectedKey)
        }
        if event.kind == .stopped {
            activities.removeValue(forKey: identity)
            scanMissCounts.removeValue(forKey: identity)
        } else if event.kind == .metadata, let previousActivity {
            activities[identity] = AgentActivity(
                agent: event.agent,
                state: previousActivity.state,
                projectName: event.projectName,
                projectPath: event.projectPath,
                sessionName: event.sessionName ?? previousActivity.sessionName,
                hostApp: event.hostApp ?? previousActivity.hostApp,
                hostWindow: previousActivity.hostWindow,
                updatedAt: previousActivity.updatedAt
            )
        } else if let state = AgentActivity.State(eventKind: event.kind) {
            let hostApp = event.hostApp ?? previousActivity?.hostApp
            let hostWindow = event.kind == .running && hostApp == .zed
                ? (ZedWindowController.frontmostWindow() ?? previousActivity?.hostWindow)
                : previousActivity?.hostWindow
            activities[identity] = AgentActivity(
                agent: event.agent,
                state: state,
                projectName: event.projectName,
                projectPath: event.projectPath,
                sessionName: event.sessionName ?? previousActivity?.sessionName,
                hostApp: hostApp,
                hostWindow: hostWindow,
                updatedAt: Date()
            )
            scanMissCounts.removeValue(forKey: identity)
        }
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        let sortedActivities = activities.sorted {
            if $0.value.state.priority != $1.value.state.priority {
                return $0.value.state.priority > $1.value.state.priority
            }
            return $0.value.updatedAt > $1.value.updatedAt
        }

        let detailedSummaries = sortedActivities.map { _, activity in
            "\(activity.agent.compactName) \(activity.displayName) \(activity.state.compactLabel)"
        }
        let compactSummary: String
        switch sortedActivities.count {
        case 0:
            compactSummary = "0 agents"
        case 1:
            compactSummary = "1 agent"
        default:
            compactSummary = "\(sortedActivities.count) agents"
        }

        let hasAttention = sortedActivities.contains { $0.value.state.needsAttention }
        let hasRunning = sortedActivities.contains { $0.value.state == .running }
        let symbolName = sortedActivities.isEmpty
            ? "circle.dashed"
            : (hasAttention ? "exclamationmark.bubble.fill" : (hasRunning ? "bolt.fill" : "checkmark.circle"))
        let button = statusItem?.button
        button?.image = coloredSymbol(
            named: symbolName,
            color: sortedActivities.first?.value.state.color ?? .secondaryLabelColor,
            accessibilityDescription: "Agent activity"
        )
        button?.title = compactSummary
        button?.toolTip = detailedSummaries.isEmpty
            ? "No active agent sessions"
            : detailedSummaries.joined(separator: ", ")

        statusMenu.removeAllItems()
        if sortedActivities.isEmpty {
            let emptyItem = NSMenuItem(title: "No active agent sessions", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            statusMenu.addItem(emptyItem)
        } else {
            for (_, activity) in sortedActivities {
                let item = NSMenuItem(
                    title: "\(activity.displayName) · \(activity.agent.displayName)",
                    action: activity.projectPath == nil ? nil : #selector(openActivity(_:)),
                    keyEquivalent: ""
                )
                item.toolTip = activity.state.label
                if let projectPath = activity.projectPath {
                    item.target = self
                    item.representedObject = ConversationTarget(
                        projectPath: projectPath,
                        hostApp: activity.hostApp,
                        hostWindow: activity.hostWindow
                    )
                }
                item.image = coloredSymbol(
                    named: activity.state.symbolName,
                    color: activity.state.color,
                    accessibilityDescription: activity.state.label
                )
                statusMenu.addItem(item)
            }
        }

        statusMenu.addItem(.separator())
        let reloadItem = NSMenuItem(
            title: "Reload Agent States",
            action: #selector(reloadAgentStates),
            keyEquivalent: "r"
        )
        reloadItem.target = self
        reloadItem.image = coloredSymbol(
            named: "arrow.clockwise",
            color: .controlAccentColor,
            accessibilityDescription: "Reload agent states"
        )
        statusMenu.addItem(reloadItem)
        let testItem = NSMenuItem(
            title: "Send Test Notification",
            action: #selector(sendTestNotification),
            keyEquivalent: ""
        )
        testItem.target = self
        statusMenu.addItem(testItem)
        statusMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    @objc
    private func reloadAgentStates() {
        scanGeneration += 1
        let generation = scanGeneration
        let revision = activityRevision
        Task { [weak self] in
            let processes = await Task.detached(priority: .utility) {
                ProcessScanner.runningAgentProcesses()
            }.value
            guard let self, generation == scanGeneration else {
                return
            }
            guard revision == activityRevision else {
                reloadAgentStates()
                return
            }
            guard let processes else {
                return
            }
            applyDetectedProcesses(processes)
        }
    }

    private func applyDetectedProcesses(_ processes: [ProcessScanner.DetectedProcess]) {
        var availableProcesses: [String: [ProcessScanner.DetectedProcess]] = [:]
        for process in processes {
            availableProcesses[process.matchingKey, default: []].append(process)
        }

        var reconciledActivities: [String: AgentActivity] = [:]
        var unmatchedActivityIDs = Set(activities.keys)
        var matchedProcessIDs = Set<Int32>()
        let eventActivities = activities
            .filter { !$0.key.hasPrefix("detected:") }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
        for (identity, activity) in eventActivities {
            let key = ProcessScanner.matchingKey(agent: activity.agent, projectPath: activity.projectPath)
            let fallbackKey = ProcessScanner.matchingKey(agent: activity.agent, projectPath: nil)
            let matchingProcess: ProcessScanner.DetectedProcess?
            if let process = availableProcesses[key]?.first(where: { !matchedProcessIDs.contains($0.processID) }) {
                matchingProcess = process
            } else if fallbackKey != key,
                      let process = availableProcesses[fallbackKey]?.first(where: {
                          !matchedProcessIDs.contains($0.processID)
                      }) {
                matchingProcess = process
            } else {
                matchingProcess = nil
            }
            guard let matchingProcess else {
                continue
            }
            reconciledActivities[identity] = AgentActivity(
                agent: activity.agent,
                state: activity.state,
                projectName: activity.projectName,
                projectPath: activity.projectPath,
                sessionName: activity.sessionName ?? matchingProcess.sessionName,
                hostApp: activity.hostApp ?? matchingProcess.hostApp,
                hostWindow: activity.hostWindow,
                updatedAt: activity.updatedAt
            )
            matchedProcessIDs.insert(matchingProcess.processID)
            unmatchedActivityIDs.remove(identity)
            unmatchedActivityIDs.remove(ProcessScanner.detectedIdentity(for: matchingProcess))
            scanMissCounts.removeValue(forKey: identity)
        }

        for process in availableProcesses.values.flatMap({ $0 }) where !matchedProcessIDs.contains(process.processID) {
            let identity = ProcessScanner.detectedIdentity(for: process)
            let existingActivity = activities[identity]
            reconciledActivities[identity] = AgentActivity(
                agent: process.agent,
                state: existingActivity?.state ?? .detected,
                projectName: process.projectPath == nil
                    ? (existingActivity?.projectName ?? process.projectName)
                    : process.projectName,
                projectPath: process.projectPath ?? existingActivity?.projectPath,
                sessionName: process.sessionName ?? existingActivity?.sessionName,
                hostApp: process.hostApp ?? existingActivity?.hostApp,
                hostWindow: existingActivity?.hostWindow,
                updatedAt: existingActivity?.updatedAt ?? Date()
            )
            unmatchedActivityIDs.remove(identity)
            scanMissCounts.removeValue(forKey: identity)
        }

        for identity in unmatchedActivityIDs {
            guard let activity = activities[identity] else {
                continue
            }
            let misses = (scanMissCounts[identity] ?? 0) + 1
            if misses < 2 {
                reconciledActivities[identity] = activity
                scanMissCounts[identity] = misses
            } else {
                scanMissCounts.removeValue(forKey: identity)
            }
        }
        activities = reconciledActivities
        refreshStatusItem()
    }

    @objc
    private func sendTestNotification() {
        deliverNotification(AgentEvent(
            agent: .opencode,
            kind: .done,
            projectPath: FileManager.default.homeDirectoryForCurrentUser.path,
            projectName: "Test project",
            message: "Notifications are configured correctly."
        ))
    }

    @objc
    private func openActivity(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ConversationTarget else {
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            ConversationLauncher.open(
                projectPath: target.projectPath,
                hostApp: target.hostApp,
                hostWindow: target.hostWindow
            )
        }
    }

    @objc
    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    nonisolated func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        shouldPresent notification: NSUserNotification
    ) -> Bool {
        true
    }

    nonisolated func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        didActivate notification: NSUserNotification
    ) {
        guard let path = notification.userInfo?["projectPath"] as? String else {
            return
        }
        openNotification(path: path, userInfo: notification.userInfo ?? [:])
        center.removeDeliveredNotification(notification)
    }

    nonisolated private func openNotification(path: String, userInfo: [AnyHashable: Any]) {
        let hostApp = (userInfo["hostApp"] as? String).flatMap(AgentHostApp.init(rawValue:))
        let hostWindow: ZedWindowTarget?
        if let processID = (userInfo["hostProcessID"] as? NSNumber)?.int32Value,
           let windowID = (userInfo["hostWindowID"] as? NSNumber)?.uint32Value {
            hostWindow = ZedWindowTarget(processID: processID, windowID: windowID)
        } else {
            hostWindow = nil
        }
        DispatchQueue.global(qos: .userInitiated).async {
            ConversationLauncher.open(
                projectPath: path,
                hostApp: hostApp,
                hostWindow: hostWindow
            )
        }
    }
}

private struct ConversationTarget {
    let projectPath: String
    let hostApp: AgentHostApp?
    let hostWindow: ZedWindowTarget?
}

private struct ZedWindowTarget {
    let processID: pid_t
    let windowID: CGWindowID
}

private struct AgentActivity {
    let agent: AgentName
    let state: State
    let projectName: String
    let projectPath: String?
    let sessionName: String?
    let hostApp: AgentHostApp?
    let hostWindow: ZedWindowTarget?
    let updatedAt: Date

    var displayName: String {
        sessionName ?? projectName
    }

    enum State: Int {
        case detected
        case ready
        case running
        case waiting
        case approval
        case error

        init?(eventKind: AgentEventKind) {
            switch eventKind {
            case .running: self = .running
            case .done: self = .ready
            case .input: self = .waiting
            case .permission: self = .approval
            case .error: self = .error
            case .metadata: return nil
            case .stopped: return nil
            }
        }

        var label: String {
            switch self {
            case .detected: "Active"
            case .ready: "Ready"
            case .running: "Running"
            case .waiting: "Waiting for answer"
            case .approval: "Needs approval"
            case .error: "Error"
            }
        }

        var compactLabel: String {
            switch self {
            case .detected: "Active"
            case .ready: "Ready"
            case .running: "Running"
            case .waiting: "Question"
            case .approval: "Approval"
            case .error: "Error"
            }
        }

        var symbolName: String {
            switch self {
            case .detected: "terminal.fill"
            case .ready: "checkmark.circle.fill"
            case .running: "bolt.circle.fill"
            case .waiting: "questionmark.bubble.fill"
            case .approval: "hand.raised.circle.fill"
            case .error: "exclamationmark.triangle.fill"
            }
        }

        var color: NSColor {
            switch self {
            case .detected: .secondaryLabelColor
            case .ready: .systemGreen
            case .running: .systemBlue
            case .waiting, .approval: .systemOrange
            case .error: .systemRed
            }
        }

        var needsAttention: Bool {
            switch self {
            case .waiting, .approval, .error: true
            case .detected, .ready, .running: false
            }
        }

        var priority: Int {
            switch self {
            case .error: 5
            case .approval: 4
            case .waiting: 3
            case .running: 2
            case .detected: 1
            case .ready: 1
            }
        }
    }
}

private func coloredSymbol(
    named symbolName: String,
    color: NSColor,
    accessibilityDescription: String
) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
    let image = NSImage(
        systemSymbolName: symbolName,
        accessibilityDescription: accessibilityDescription
    )?.withSymbolConfiguration(configuration)
    image?.isTemplate = false
    return image
}

private enum ProcessScanner {
    struct DetectedProcess: Sendable {
        let processID: Int32
        let agent: AgentName
        let projectPath: String?
        let sessionName: String?
        let hostApp: AgentHostApp?

        var matchingKey: String {
            ProcessScanner.matchingKey(agent: agent, projectPath: projectPath)
        }

        var projectName: String {
            projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? "PID \(processID)"
        }
    }

    static func runningAgentProcesses() -> [DetectedProcess]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,tty=,comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let commands = String(data: data, encoding: .utf8)
            else {
                return nil
            }

            let records = commands.split(separator: "\n").compactMap { line -> ProcessRecord? in
                let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
                guard fields.count == 4,
                      let processID = Int32(fields[0]),
                      let parentProcessID = Int32(fields[1])
                else {
                    return nil
                }
                return ProcessRecord(
                    processID: processID,
                    parentProcessID: parentProcessID,
                    terminal: String(fields[2]),
                    command: String(fields[3])
                )
            }
            let recordsByProcessID = Dictionary(uniqueKeysWithValues: records.map { ($0.processID, $0) })
            let detectedAgents: [(Int32, AgentName)] = records.compactMap { record in
                guard record.terminal != "??", record.terminal != "-" else {
                    return nil
                }
                let executable = URL(fileURLWithPath: record.command)
                    .lastPathComponent
                    .lowercased()
                if executable == "opencode" {
                    return (record.processID, AgentName.opencode)
                }
                if executable == "claude" || executable == "claude-code" {
                    return (record.processID, AgentName.claude)
                }
                if executable == "codex" || executable.hasPrefix("codex-") {
                    return (record.processID, AgentName.codex)
                }
                return nil
            }
            let agentsByProcessID = Dictionary(uniqueKeysWithValues: detectedAgents)
            let workingDirectories = workingDirectories(for: Array(agentsByProcessID.keys))
            let openCodeProcessIDs = agentsByProcessID.compactMap { processID, agent in
                agent == .opencode ? processID : nil
            }
            let openCodeProcessCounts = Dictionary(grouping: openCodeProcessIDs, by: { processID in
                workingDirectories[processID].map(standardizedProjectPath) ?? ""
            }).mapValues(\.count)
            let sessionsByDirectory = openCodeSessionsByDirectory(
                paths: agentsByProcessID.compactMap { processID, agent in
                    guard agent == .opencode, let path = workingDirectories[processID] else {
                        return nil
                    }
                    return standardizedProjectPath(path)
                },
                executable: openCodeExecutable(processIDs: openCodeProcessIDs)
            )
            return agentsByProcessID.sorted { $0.key < $1.key }.map { processID, agent in
                let projectPath = workingDirectories[processID].map(standardizedProjectPath)
                let sessionName = projectPath.flatMap { path in
                    agent == .opencode && openCodeProcessCounts[path] == 1
                        ? sessionsByDirectory[path]
                        : nil
                }
                return DetectedProcess(
                    processID: processID,
                    agent: agent,
                    projectPath: projectPath,
                    sessionName: sessionName,
                    hostApp: hostApp(for: processID, recordsByProcessID: recordsByProcessID)
                )
            }
        } catch {
            return nil
        }
    }

    static func detectedIdentity(for process: DetectedProcess) -> String {
        "detected:\(process.agent.rawValue):\(process.processID)"
    }

    static func matchingKey(agent: AgentName, projectPath: String?) -> String {
        "\(agent.rawValue):\(projectPath.map(standardizedProjectPath) ?? "")"
    }

    private static func hostApp(
        for processID: Int32,
        recordsByProcessID: [Int32: ProcessRecord]
    ) -> AgentHostApp? {
        var currentProcessID: Int32? = processID
        var visited = Set<Int32>()
        while let current = currentProcessID,
              current > 0,
              visited.insert(current).inserted,
              let record = recordsByProcessID[current] {
            let executable = URL(fileURLWithPath: record.command).lastPathComponent.lowercased()
            if executable == "ghostty" {
                return .ghostty
            }
            if executable == "zed" {
                return .zed
            }
            currentProcessID = record.parentProcessID
        }
        return nil
    }

    private struct ProcessRecord {
        let processID: Int32
        let parentProcessID: Int32
        let terminal: String
        let command: String
    }

    private static func workingDirectories(for processIDs: [Int32]) -> [Int32: String] {
        guard !processIDs.isEmpty else {
            return [:]
        }

        var result = lsofWorkingDirectories(for: processIDs)
        for processID in processIDs where result[processID] == nil {
            result.merge(lsofWorkingDirectories(for: [processID])) { existing, _ in existing }
        }
        return result
    }

    private static func lsofWorkingDirectories(for processIDs: [Int32]) -> [Int32: String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", processIDs.map(String.init).joined(separator: ","), "-d", "cwd", "-Fn"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let fields = String(data: data, encoding: .utf8) else {
                return [:]
            }

            var result: [Int32: String] = [:]
            var currentProcessID: Int32?
            for field in fields.split(separator: "\n") {
                if field.first == "p" {
                    currentProcessID = Int32(field.dropFirst())
                } else if field.first == "n", let currentProcessID {
                    result[currentProcessID] = String(field.dropFirst())
                }
            }
            return result
        } catch {
            return [:]
        }
    }

    private static func openCodeSessionsByDirectory(
        paths: [String],
        executable: String?
    ) -> [String: String] {
        let paths = Set(paths)
        guard !paths.isEmpty, let executable else {
            return [:]
        }

        let pathList = paths
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ",")
        let query = """
        SELECT title, directory
        FROM session
        WHERE parent_id IS NULL
          AND time_archived IS NULL
          AND directory IN (\(pathList))
        ORDER BY time_updated DESC
        """
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--pure", "db", query, "--format", "json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let sessions = try? JSONDecoder().decode([OpenCodeSession].self, from: data)
            else {
                return [:]
            }

            var result: [String: String] = [:]
            for session in sessions {
                let path = standardizedProjectPath(session.directory)
                if result[path] == nil {
                    result[path] = session.title
                }
            }
            return result
        } catch {
            return [:]
        }
    }

    private static func openCodeExecutable(processIDs: [Int32]) -> String? {
        for processID in processIDs {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-a", "-p", String(processID), "-d", "txt", "-Fn"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let fields = String(data: data, encoding: .utf8),
                   let path = fields.split(separator: "\n")
                    .filter({ $0.first == "n" })
                    .map({ String($0.dropFirst()) })
                    .first(where: {
                        URL(fileURLWithPath: $0).lastPathComponent.lowercased() == "opencode"
                            && FileManager.default.isExecutableFile(atPath: $0)
                    }) {
                    return path
                }
            } catch {
                continue
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            "\(home)/.opencode/bin/opencode",
            "\(home)/.local/bin/opencode"
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private struct OpenCodeSession: Decodable {
        let title: String
        let directory: String
    }
}

private func standardizedProjectPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

private extension AgentName {
    var compactName: String {
        switch self {
        case .opencode: "OpenCode"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

private enum ConversationLauncher {
    nonisolated static func open(
        projectPath: String,
        hostApp: AgentHostApp?,
        hostWindow: ZedWindowTarget?
    ) {
        let expandedPath = NSString(string: projectPath).expandingTildeInPath

        if hostApp == .zed,
           let hostWindow,
           ZedWindowController.focus(target: hostWindow) {
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return
        }

        if hostApp == .ghostty {
            activate(application: "Ghostty")
            return
        }

        if let executable = zedExecutable() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ConversationLaunchPolicy.zedArguments(projectPath: expandedPath)
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return
                }
            } catch {
                // Fall through to Launch Services when the CLI cannot start.
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Zed", expandedPath]
        try? process.run()
    }

    nonisolated private static func activate(application: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", application]
        try? process.run()
    }

    nonisolated private static func zedExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/usr/local/bin/zed",
            "/opt/homebrew/bin/zed",
            "\(home)/.local/bin/zed"
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }
}

@_silgen_name("GetProcessForPID")
private func legacyGetProcessForPID(
    _ processID: pid_t,
    _ processSerialNumber: UnsafeMutablePointer<ProcessSerialNumber>
) -> OSStatus

private enum ZedWindowController {
    private static let bundleIdentifier = "dev.zed.Zed"
    private static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    nonisolated static func frontmostWindow() -> ZedWindowTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier == bundleIdentifier
        else {
            return nil
        }

        return windows().first(where: { window in
            (window[kCGWindowOwnerPID as String] as? pid_t) == application.processIdentifier
                && (window[kCGWindowLayer as String] as? Int) == 0
                && (window[kCGWindowAlpha as String] as? Double ?? 0) > 0
                && (window[kCGWindowIsOnscreen as String] as? Bool) == true
                && windowArea(window) > 10_000
        }).flatMap { window in
            guard let windowID = window[kCGWindowNumber as String] as? CGWindowID else {
                return nil
            }
            return ZedWindowTarget(processID: application.processIdentifier, windowID: windowID)
        }
    }

    nonisolated static func focus(target: ZedWindowTarget) -> Bool {
        guard let window = windows().first(where: {
            ($0[kCGWindowNumber as String] as? CGWindowID) == target.windowID
        }), (window[kCGWindowOwnerPID as String] as? pid_t) == target.processID,
        NSRunningApplication(processIdentifier: target.processID)?.bundleIdentifier == bundleIdentifier,
        let handle = dlopen(skyLightPath, RTLD_LAZY)
        else {
            return false
        }
        defer { dlclose(handle) }

        typealias FocusWindow = @convention(c) (
            UnsafeMutablePointer<ProcessSerialNumber>,
            CGWindowID,
            UInt32
        ) -> CGError
        typealias PostEvent = @convention(c) (
            UnsafeMutablePointer<ProcessSerialNumber>,
            UnsafeMutablePointer<UInt8>
        ) -> CGError
        guard let focusSymbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions"),
              let eventSymbol = dlsym(handle, "SLPSPostEventRecordTo")
        else {
            return false
        }

        let focusWindow = unsafeBitCast(focusSymbol, to: FocusWindow.self)
        let postEvent = unsafeBitCast(eventSymbol, to: PostEvent.self)
        var processSerialNumber = ProcessSerialNumber()
        guard legacyGetProcessForPID(target.processID, &processSerialNumber) == noErr,
              focusWindow(&processSerialNumber, target.windowID, 0x200) == .success
        else {
            return false
        }

        return makeKeyWindow(
            target.windowID,
            processSerialNumber: &processSerialNumber,
            postEvent: postEvent
        )
    }

    nonisolated private static func windows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
    }

    nonisolated private static func windowArea(_ window: [String: Any]) -> Double {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double
        else {
            return 0
        }
        return width * height
    }

    nonisolated private static func makeKeyWindow(
        _ windowID: CGWindowID,
        processSerialNumber: inout ProcessSerialNumber,
        postEvent: (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    ) -> Bool {
        var windowID = windowID
        var point = CGPoint(x: 300_000, y: 300_000)
        var event = [UInt8](repeating: 0, count: 0x100)
        // Window Server mouse-down record targeted outside the window's content.
        event[0x04] = 0xf8
        event[0x08] = 0x01
        event[0x3a] = 0x10
        withUnsafeBytes(of: &windowID) { bytes in
            event.replaceSubrange(0x3c..<(0x3c + bytes.count), with: bytes)
        }
        withUnsafeBytes(of: &point) { bytes in
            event.replaceSubrange(0x20..<(0x20 + bytes.count), with: bytes)
        }
        return postEvent(&processSerialNumber, &event) == .success
    }
}
