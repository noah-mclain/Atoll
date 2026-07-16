/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import ApplicationServices
import Combine
import Defaults
import Foundation
import SwiftUI

/// A single tool invocation surfaced in the agent checklist.
struct AgentToolCall: Identifiable, Equatable {
    let id: String       // the tool_use id, or a synthesized fallback
    let label: String    // e.g. "Reading nz_2.png", "Running grep -n"
    var isComplete: Bool // has a matching tool_result arrived?
}

/// A step from the agent's own checklist — Claude Code's TodoWrite list or
/// Codex's update_plan. Unlike `AgentToolCall` this is the agent's *plan*, so
/// it carries the steps it hasn't started yet.
struct AgentTodo: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable {
        case pending
        case inProgress
        case completed

        init(raw: String) {
            switch raw.lowercased() {
            case "in_progress", "in-progress", "active": self = .inProgress
            case "completed", "complete", "done":        self = .completed
            default:                                     self = .pending
            }
        }

        var iconName: String {
            switch self {
            case .pending:    return "circle"
            case .inProgress: return "play.fill"
            case .completed:  return "checkmark.circle.fill"
            }
        }
    }

    /// Position in the list — the agent republishes the checklist whole, so
    /// the index is the stable identity across updates.
    let id: Int
    let text: String
    let status: Status
}

/// One selectable answer from an agent's AskUserQuestion prompt.
struct AgentPromptOption: Identifiable, Equatable {
    let index: Int      // 0-based position — pressing "index + 1" answers it
    let label: String
    let detail: String?

    var id: Int { index }
}

struct AgentSession: Identifiable, Equatable {
    enum Kind: String {
        case claudeCode = "Claude"
        case codex = "Codex"

        /// SF Symbol for the header/inline icon.
        var iconName: String {
            switch self {
            case .claudeCode: return "sparkle"
            case .codex:      return "chevron.left.forwardslash.chevron.right"
            }
        }

        var accent: Color {
            switch self {
            case .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.26) // Claude orange
            case .codex:      return Color(red: 0.30, green: 0.52, blue: 0.96) // Codex blue
            }
        }
    }

    enum ActivityState: Equatable {
        /// Log file written to within the working threshold — the agent is
        /// actively generating or running tools.
        case working
        /// The agent's last turn is an unanswered AskUserQuestion — it
        /// explicitly offered options and is waiting on the user's pick.
        case waitingForInput
        /// The agent finished its turn and is idle (not asking anything).
        case done
    }

    let id: String              // absolute path of the session log
    let kind: Kind
    let projectName: String
    var state: ActivityState
    var lastActivity: Date
    var currentTool: String?
    /// Recent tool calls, oldest first; the last is current while working.
    var toolCalls: [AgentToolCall] = []
    /// The agent's own checklist, when it keeps one. Preferred over
    /// `toolCalls` in the panel: it shows what's left, not just what ran.
    var todos: [AgentTodo] = []
    /// Latest assistant prose, shown in the detail bubble.
    var latestText: String?
    /// Human-friendly session summary, if the transcript carries one.
    var title: String?
    /// The question the agent is blocked on, when `state == .waitingForInput`.
    var pendingQuestion: String?
    /// Identity of the prompt itself (its tool call), so re-asking the same
    /// question is told apart from still waiting on the first one.
    var pendingPromptID: String?
    /// Selectable answers for the pending question, in prompt order.
    var pendingOptions: [AgentPromptOption] = []

    /// Header status line, e.g. "Thinking", "Needs your input".
    var statusLabel: String {
        switch state {
        case .waitingForInput:
            return "Needs your input"
        case .done:
            return "Finished"
        case .working:
            switch kind {
            case .claudeCode: return "Thinking"
            case .codex:      return "Working on your task"
            }
        }
    }

    /// Title for compact surfaces: the transcript summary, else the project.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return projectName
    }
}

/// Surfaces running AI coding-agent sessions (Claude Code, Codex CLI) as a
/// notch live activity by watching their session logs on disk.
///
/// Both CLIs append JSONL transcript files as they work:
///   * Claude Code — ~/.claude/projects/<encoded-path>/<uuid>.jsonl
///   * Codex CLI   — ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
///
/// A session whose log was written in the last `workingThreshold` seconds is
/// "working"; one quiet for longer (but under `sessionTimeout`) is "waiting".
/// Detection is pure file-metadata polling — cheap, no subprocesses — and
/// the log tail is parsed only when the file actually changed, to pull out
/// the current tool name for display.
@MainActor
final class AgentActivityMonitor: ObservableObject {

    static let shared = AgentActivityMonitor()

    @Published private(set) var sessions: [AgentSession] = []

    var workingSessions: [AgentSession] { sessions.filter { $0.state == .working } }

    /// Sessions worth surfacing in the closed notch: actively working, waiting
    /// on the user, or freshly finished (within the done grace window). An
    /// idle-finished session drops out so the pill doesn't linger for minutes.
    var liveSessions: [AgentSession] {
        sessions.filter { session in
            switch session.state {
            case .working, .waitingForInput:
                return true
            case .done:
                guard let since = doneSince[session.id] else { return false }
                return Date().timeIntervalSince(since) < Self.doneGrace
            }
        }
    }

    var hasActivity: Bool { !liveSessions.isEmpty }

    private static let workingThreshold: TimeInterval = 20
    private static let sessionTimeout: TimeInterval = 15 * 60
    private static let pollInterval: TimeInterval = 2
    /// How long a finished session keeps showing its "Finished" pill before
    /// dropping out — long enough to notice, short enough not to squat.
    private static let doneGrace: TimeInterval = 4

    private var pollTimer: Timer?
    private var lastKnownSizes: [String: UInt64] = [:]
    private var lastKnownParses: [String: ParsedTranscript] = [:]
    /// Checklist state per transcript, folded forward as each file grows.
    private var planStates: [String: PlanState] = [:]
    private var planCursors: [String: UInt64] = [:]
    private var planScansInFlight: Set<String> = []
    /// Transcripts that grew while their scan was running, and so need another.
    private var planRescansRequested: Set<String> = []
    /// When each session first entered the `.done` state, for the grace window.
    private var doneSince: [String: Date] = [:]
    /// Live-session IDs at the last publish, so grace-window expiry re-renders.
    private var lastLiveIDs: Set<String> = []
    /// Prompt identities (session + question + options) seen waiting at the
    /// last poll, so only a genuinely new prompt interrupts — a session that
    /// blips back to `.working` on a heartbeat write and returns with the
    /// same unanswered question must not pop the notch again.
    private var lastWaitingPromptKeys: Set<String> = []
    private var promptCollapseWorkItem: DispatchWorkItem?
    /// Forces a publish the moment the earliest done-grace window expires,
    /// instead of waiting for the next poll tick.
    private var graceExpiryWorkItem: DispatchWorkItem?

    /// The slice of a transcript we surface in the UI.
    private struct ParsedTranscript: Equatable {
        var toolCalls: [AgentToolCall] = []
        var latestText: String?
        var title: String?
        var currentTool: String?
        var awaitingChoice: Bool = false
        var pendingQuestion: String?
        var pendingPromptID: String?
        var pendingOptions: [AgentPromptOption] = []
    }

    /// How many trailing tool calls to keep for the checklist.
    private static let checklistDepth = 40

    private init() {
        start()
    }

    func start() {
        guard pollTimer == nil else { return }
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in
                AgentActivityMonitor.shared.poll()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        sessions = []
    }

    /// Apps a coding agent plausibly runs in, and so the only ones we'll post
    /// synthetic keys into.
    private static let terminalBundleIDs = [
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    /// Running terminals, in the order we'd guess between them.
    private static var runningTerminals: [NSRunningApplication] {
        terminalBundleIDs.compactMap { bundleID in
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
        }
    }

    /// The terminal most likely running `session`. With several open, the one
    /// whose window names the session's project wins — terminals put the
    /// working directory in the title, which is the only link back from a
    /// transcript on disk to the window it's being typed in.
    private static func terminal(for session: AgentSession?) -> NSRunningApplication? {
        let running = runningTerminals
        guard running.count > 1, let project = session?.projectName, !project.isEmpty else {
            return running.first
        }
        return running.first { hasWindow(in: $0, naming: project) } ?? running.first
    }

    private static func hasWindow(in app: NSRunningApplication, naming project: String) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }

        for window in windows.prefix(8) {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String else { continue }
            if title.localizedCaseInsensitiveContains(project) { return true }
        }
        return false
    }

    /// Brings the terminal running a session to the front so the user can
    /// answer a prompt, and reports which one it activated.
    @discardableResult
    static func focusAgentTerminal(for session: AgentSession? = nil) -> NSRunningApplication? {
        guard let app = terminal(for: session) else { return nil }
        app.activate(options: [.activateAllWindows])
        return app
    }

    // MARK: - Answering prompts

    /// Answers a pending AskUserQuestion by focusing the session's terminal
    /// and pressing the option's number key — the CLI prompt selects on the
    /// bare digit.
    static func answer(option: AgentPromptOption, in session: AgentSession) {
        withFocusedTerminal(for: session) {
            postDigitKey(option.index + 1)
        }
    }

    /// Types free-form text into the session's terminal and submits it.
    static func send(text: String, to session: AgentSession) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withFocusedTerminal(for: session) {
            typeText(trimmed)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                postKey(36) // Return
            }
        }
    }

    /// Runs `keystrokes` only once the intended terminal is actually frontmost.
    /// Activation is asynchronous and can fail outright, and these paths type
    /// into whatever holds focus — a digit, or a whole sentence and Return,
    /// arriving in a plain shell would run as a command. So the target is
    /// re-checked after the switch and the keys are dropped if it didn't take.
    private static func withFocusedTerminal(for session: AgentSession, keystrokes: @escaping () -> Void) {
        guard let target = focusAgentTerminal(for: session) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
            keystrokes()
        }
    }

    private static func postDigitKey(_ digit: Int) {
        let keycodes: [Int: CGKeyCode] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25]
        guard let code = keycodes[digit] else { return }
        postKey(code)
    }

    private static func postKey(_ code: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }

    /// Posts arbitrary text as synthetic key events (20 UTF-16 units per
    /// event, the CGEvent payload cap).
    private static func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            let end = min(start + 20, units.count)
            var chunk = Array(units[start..<end])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                up.post(tap: .cghidEventTap)
            }
            start = end
        }
    }

    // MARK: - Polling

    private func poll() {
        var found: [AgentSession] = []
        found.append(contentsOf: scanClaudeCode())
        found.append(contentsOf: scanCodex())

        // One entry per project — keep the most recently active session.
        var byProject: [String: AgentSession] = [:]
        for session in found {
            let key = "\(session.kind.rawValue)|\(session.projectName)"
            if let existing = byProject[key], existing.lastActivity >= session.lastActivity {
                continue
            }
            byProject[key] = session
        }

        let updated = byProject.values.sorted { $0.lastActivity > $1.lastActivity }

        // Track when each session first went `.done` (for the grace window),
        // and forget sessions that changed state or disappeared.
        let now = Date()
        let presentIDs = Set(updated.map(\.id))
        for session in updated where session.state == .done && doneSince[session.id] == nil {
            doneSince[session.id] = now
        }
        for session in updated where session.state != .done {
            doneSince.removeValue(forKey: session.id)
        }
        doneSince = doneSince.filter { presentIDs.contains($0.key) }

        // Publish when the sessions themselves change, or when the set of
        // "live" (shown in the closed notch) sessions changes — including a
        // finished pill ageing out of its grace window.
        let liveIDs = Set(liveIDs(from: updated))
        if updated != sessions || liveIDs != lastLiveIDs {
            sessions = updated
            lastLiveIDs = liveIDs
        }

        // A session that just started waiting on a choice interrupts like a
        // notification: pop the notch open on the agent panel, then collapse
        // back to the "Waiting for your input" pill unless the pointer stays.
        let waitingKeys = Set(updated.filter { $0.state == .waitingForInput }.map(Self.promptKey))
        let newlyWaiting = !waitingKeys.subtracting(lastWaitingPromptKeys).isEmpty
        // Keep keys for sessions merely blipping through `.working` on a
        // transcript write, so the same question can't re-interrupt; drop
        // keys for sessions that finished or vanished.
        let currentIDs = Set(updated.filter { $0.state != .done }.map(\.id))
        lastWaitingPromptKeys = waitingKeys.union(
            lastWaitingPromptKeys.filter { key in
                currentIDs.contains(where: { key.hasPrefix($0 + "|") })
            }
        )
        if newlyWaiting && Defaults[.enableAgentLiveActivity] {
            presentPromptInterruption()
        }

        // Re-publish exactly when the earliest finished pill's grace runs
        // out, so it doesn't overstay by a poll tick.
        graceExpiryWorkItem?.cancel()
        graceExpiryWorkItem = nil
        // Only windows that haven't elapsed yet need waking for: a finished
        // session keeps its `doneSince` stamp until it ages out of the scan
        // entirely, and re-arming on an expired one would clamp to the floor
        // and spin the poll for the rest of the timeout.
        let unexpired = doneSince.values.filter { now.timeIntervalSince($0) < Self.doneGrace }
        if let earliest = unexpired.min() {
            let fireIn = max(0.05, earliest.addingTimeInterval(Self.doneGrace).timeIntervalSinceNow)
            let work = DispatchWorkItem { [weak self] in self?.poll() }
            graceExpiryWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + fireIn, execute: work)
        }
    }

    /// Identity of a pending prompt. Keyed on the prompt's own tool call
    /// rather than its wording: a re-parse of the same unanswered question
    /// yields the same key (so it can't re-interrupt), while an agent asking
    /// a word-for-word identical question later yields a new one (so it can).
    private static func promptKey(for session: AgentSession) -> String {
        "\(session.id)|\(session.pendingPromptID ?? session.pendingQuestion ?? "")"
    }

    /// Opens the notch on the agent panel for a fresh prompt and schedules
    /// the collapse. While the pointer is over a notch window the collapse
    /// keeps deferring, so an actively-reading user isn't cut off.
    private func presentPromptInterruption() {
        DynamicIslandViewCoordinator.shared.currentView = .agent
        AppDelegate.shared?.openNotchForInterruption()
        schedulePromptCollapse(after: 10)
    }

    private func schedulePromptCollapse(after delay: TimeInterval) {
        promptCollapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard DynamicIslandViewCoordinator.shared.currentView == .agent else { return }
            if Self.isPointerOverNotch() {
                self.schedulePromptCollapse(after: 4)
                return
            }
            AppDelegate.shared?.closeNotchAfterInterruption()
        }
        promptCollapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func isPointerOverNotch() -> Bool {
        guard let delegate = AppDelegate.shared else { return false }
        let mouse = NSEvent.mouseLocation
        var frames = delegate.windows.values.map(\.frame)
        if let single = delegate.window { frames.append(single.frame) }
        return frames.contains { $0.contains(mouse) }
    }

    /// IDs of sessions that should show in the closed notch, computed from a
    /// candidate list (so it works before `sessions` is assigned).
    private func liveIDs(from candidates: [AgentSession]) -> [String] {
        candidates.compactMap { session in
            switch session.state {
            case .working, .waitingForInput:
                return session.id
            case .done:
                guard let since = doneSince[session.id] else { return nil }
                return Date().timeIntervalSince(since) < Self.doneGrace ? session.id : nil
            }
        }
    }

    private func scanClaudeCode() -> [AgentSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }

        var results: [AgentSession] = []
        for dir in projectDirs {
            guard let logs = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for log in logs where log.pathExtension == "jsonl" {
                guard let session = makeSession(
                    logURL: log,
                    kind: .claudeCode,
                    projectName: Self.claudeProjectName(from: dir.lastPathComponent)
                ) else { continue }
                results.append(session)
            }
        }
        return results
    }

    private func scanCodex() -> [AgentSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        // Only today's (and yesterday's, around midnight) date folders can
        // contain live sessions — avoids walking the whole history.
        let calendar = Calendar.current
        let days = [Date(), calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"

        var results: [AgentSession] = []
        for day in days {
            let dayDir = root.appendingPathComponent(formatter.string(from: day))
            guard let logs = try? FileManager.default.contentsOfDirectory(
                at: dayDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for log in logs where log.pathExtension == "jsonl" {
                guard let session = makeSession(logURL: log, kind: .codex, projectName: "Codex") else { continue }
                results.append(session)
            }
        }
        return results
    }

    private func makeSession(logURL: URL, kind: AgentSession.Kind, projectName: String) -> AgentSession? {
        guard
            let values = try? logURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
            let modified = values.contentModificationDate
        else { return nil }

        let age = Date().timeIntervalSince(modified)
        guard age < Self.sessionTimeout else {
            lastKnownSizes.removeValue(forKey: logURL.path)
            lastKnownParses.removeValue(forKey: logURL.path)
            planStates.removeValue(forKey: logURL.path)
            planCursors.removeValue(forKey: logURL.path)
            planRescansRequested.remove(logURL.path)
            return nil
        }

        // Re-parse only when the file actually grew — parsing is the only
        // expensive step, so cache the last result per path.
        var parsed = lastKnownParses[logURL.path] ?? ParsedTranscript()
        let size = UInt64(values.fileSize ?? 0)
        if lastKnownSizes[logURL.path] != size {
            lastKnownSizes[logURL.path] = size
            parsed = Self.parseTranscript(in: logURL, kind: kind)
            lastKnownParses[logURL.path] = parsed
            schedulePlanScan(for: logURL)
        }

        // Recently written → working. Otherwise it's the user's move: only
        // "waiting for input" when the agent actually posed a question or an
        // AskUserQuestion prompt; a plain finished turn is "done".
        let state: AgentSession.ActivityState
        if age < Self.workingThreshold {
            state = .working
        } else if parsed.awaitingChoice {
            state = .waitingForInput
        } else {
            state = .done
        }

        // While the agent is working, the last tool call is still in flight;
        // once it goes quiet, everything it launched has settled.
        var toolCalls = parsed.toolCalls
        if state != .working {
            for index in toolCalls.indices { toolCalls[index].isComplete = true }
        }

        return AgentSession(
            id: logURL.path,
            kind: kind,
            projectName: projectName,
            state: state,
            lastActivity: modified,
            currentTool: state == .working ? parsed.currentTool : nil,
            toolCalls: toolCalls,
            todos: planStates[logURL.path]?.todos ?? [],
            latestText: parsed.latestText,
            title: parsed.title,
            pendingQuestion: state == .waitingForInput ? parsed.pendingQuestion : nil,
            pendingPromptID: state == .waitingForInput ? parsed.pendingPromptID : nil,
            pendingOptions: state == .waitingForInput ? parsed.pendingOptions : []
        )
    }

    // MARK: - Log parsing

    /// Reads the tail of the JSONL transcript and reconstructs the recent
    /// tool-call checklist, the latest assistant prose, and a session title.
    private static func parseTranscript(in url: URL, kind: AgentSession.Kind) -> ParsedTranscript {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ParsedTranscript() }
        defer { try? handle.close() }

        let tailLength: UInt64 = 64_000
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > tailLength ? fileSize - tailLength : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return ParsedTranscript() }
        // Decoded leniently: the tail cut lands mid-line, and can land inside
        // a multi-byte character — a strict decode would fail the whole read
        // and blank the panel. The damaged leading line fails its JSON decode
        // and is skipped below.
        let text = String(decoding: data, as: UTF8.self)

        var ordered: [(id: String, label: String)] = []
        var resultIDs: Set<String> = []
        var latestText: String?
        var title: String?
        var syntheticIndex = 0
        // Question + options of the most recent AskUserQuestion, surfaced when
        // it goes unanswered so the panel can render the choices.
        var lastAskPrompt: (question: String?, options: [AgentPromptOption]) = (nil, [])
        // The final assistant action, used to tell "waiting for a choice" from
        // "just finished": .askQuestion carries the AskUserQuestion tool id
        // so it can be checked against resultIDs below.
        enum LastAction { case none, askQuestion(String), text, toolOther, toolResult }
        var lastAction: LastAction = .none

        // Chronological pass so ordering and completion resolve naturally.
        for line in text.split(separator: "\n") {
            guard
                let lineData = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let summary = object["summary"] as? String, !summary.isEmpty {
                title = summary
            }

            // Claude Code: assistant/user messages carry a content array.
            if let message = object["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    switch block["type"] as? String {
                    case "tool_use":
                        let id = block["id"] as? String ?? "auto-\(syntheticIndex)"
                        syntheticIndex += 1
                        let name = block["name"] as? String ?? ""
                        let input = normalizedInput(block["input"])
                        ordered.append((id, friendlyLabel(tool: name, input: input)))
                        if name == "AskUserQuestion" {
                            lastAction = .askQuestion(id)
                            lastAskPrompt = Self.promptPayload(from: input)
                        } else {
                            lastAction = .toolOther
                        }
                    case "tool_result":
                        if let id = block["tool_use_id"] as? String { resultIDs.insert(id) }
                        lastAction = .toolResult
                    case "text":
                        if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                            latestText = t
                            lastAction = .text
                        }
                    default:
                        break
                    }
                }
                continue
            }

            // Codex rollout: flat function_call / function_call_output records.
            switch object["type"] as? String {
            case let type? where type.contains("function_call_output"):
                if let id = object["call_id"] as? String { resultIDs.insert(id) }
                lastAction = .toolResult
            case let type? where type.contains("function_call"):
                let id = object["call_id"] as? String ?? "auto-\(syntheticIndex)"
                syntheticIndex += 1
                let name = object["name"] as? String ?? ""
                ordered.append((id, friendlyLabel(tool: name, input: normalizedInput(object["arguments"]))))
                lastAction = .toolOther
            case "message":
                if let content = object["content"] as? [[String: Any]] {
                    for block in content where (block["type"] as? String)?.contains("text") == true {
                        if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                            latestText = t
                            lastAction = .text
                        }
                    }
                }
            default:
                break
            }
        }

        let recent = ordered.suffix(checklistDepth).map {
            AgentToolCall(id: $0.id, label: $0.label, isComplete: resultIDs.contains($0.id))
        }
        let currentTool = recent.last(where: { !$0.isComplete })?.label ?? recent.last?.label

        // The agent genuinely wants input only when it explicitly presented
        // options — an unanswered AskUserQuestion. A turn that merely ends on a
        // question mark ("Want me to continue?") is just a finished turn, not a
        // blocking choice, so it must read as `done`, not "Needs your input".
        let awaitingChoice: Bool
        var promptID: String?
        switch lastAction {
        case .askQuestion(let id):
            awaitingChoice = !resultIDs.contains(id)
            promptID = id
        default:
            awaitingChoice = false
        }

        return ParsedTranscript(
            toolCalls: recent,
            latestText: latestText.map(truncateForBubble),
            title: title,
            currentTool: currentTool,
            awaitingChoice: awaitingChoice,
            pendingQuestion: awaitingChoice ? lastAskPrompt.question : nil,
            pendingPromptID: awaitingChoice ? promptID : nil,
            pendingOptions: awaitingChoice ? lastAskPrompt.options : []
        )
    }

    // MARK: - Checklist reconstruction

    /// Lines worth decoding when rebuilding the checklist. "Task #" catches
    /// the TaskCreate/TaskUpdate results, which name neither tool.
    nonisolated private static let planMarkers = ["TodoWrite", "TaskCreate", "TaskUpdate", "update_plan", "Task #", "task #"]

    /// The checklist rebuilt from a transcript, and the bookkeeping needed to
    /// keep rebuilding it as the file grows.
    ///
    /// This can't be read from a tail the way the prose is. TodoWrite and
    /// update_plan republish the whole list, so the last one wins — but
    /// TaskCreate/TaskUpdate only mutate it, and the subject of a task lives
    /// solely in its creation. In practice an agent creates its tasks up front
    /// and updates them for the rest of the session, leaving the creations
    /// megabytes behind the latest update, so the state is instead folded
    /// forward from a byte cursor: transcripts are append-only, so each scan
    /// only has to read what was added since the last one.
    private struct PlanState: Sendable {
        /// A task assembled across its TaskCreate and later TaskUpdates.
        struct TaskEntry: Sendable {
            var subject: String
            var activeForm: String?
            var status: AgentTodo.Status
        }

        /// The most recent whole-list publication (TodoWrite / update_plan).
        var republished: [AgentTodo] = []
        /// TaskCreate tool_use id → subject, until its result names the task.
        var pendingCreates: [String: String] = [:]
        /// Task numbers in creation order.
        var order: [String] = []
        var tasks: [String: TaskEntry] = [:]
        /// Whether the Task tools were touched more recently than TodoWrite —
        /// a session that used both shows whichever it's actually driving.
        var tasksAreCurrent = false

        var todos: [AgentTodo] {
            guard tasksAreCurrent else { return republished }
            let reconstructed = order.enumerated().compactMap { index, key -> AgentTodo? in
                guard let entry = tasks[key] else { return nil }
                let text = entry.status == .inProgress ? (entry.activeForm ?? entry.subject) : entry.subject
                return AgentTodo(id: index, text: text, status: entry.status)
            }
            return reconstructed.isEmpty ? republished : reconstructed
        }
    }

    /// Reads whatever the transcript gained since `cursor` and folds its plan
    /// events into `state`. Runs off the main actor: the first scan of an
    /// already-long session reads the whole file.
    nonisolated private static func scanPlanChunk(
        url: URL, from cursor: UInt64, state: PlanState
    ) -> (state: PlanState, cursor: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (state, cursor) }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        // A shorter file isn't the one we were reading — rebuild from scratch.
        var state = state
        var start = cursor
        if size < cursor {
            state = PlanState()
            start = 0
        }
        guard size > start else { return (state, size) }

        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return (state, start) }

        // Stop at the last newline and leave the cursor there, so a record
        // still being written is read whole by the next scan instead of being
        // split across two and lost by both.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return (state, start) }
        let complete = data[data.startIndex...lastNewline]
        advancePlan(&state, with: String(decoding: complete, as: UTF8.self))
        return (state, start + UInt64(complete.count))
    }

    nonisolated private static func advancePlan(_ state: inout PlanState, with text: String) {
        for line in text.split(separator: "\n") {
            guard planMarkers.contains(where: { line.contains($0) }) else { continue }
            guard
                let lineData = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let message = object["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    switch block["type"] as? String {
                    case "tool_use":
                        let input = normalizedInput(block["input"])
                        switch block["name"] as? String {
                        case "TodoWrite":
                            state.republished = todoList(from: input)
                            state.tasksAreCurrent = false
                        case "TaskCreate":
                            if let id = block["id"] as? String, let subject = cleanString(input?["subject"]) {
                                state.pendingCreates[id] = subject
                            }
                        case "TaskUpdate":
                            guard let key = taskKey(input?["taskId"]), var entry = state.tasks[key] else { break }
                            entry.status = AgentTodo.Status(raw: input?["status"] as? String ?? "")
                            if let form = cleanString(input?["activeForm"]) { entry.activeForm = form }
                            if let subject = cleanString(input?["subject"]) { entry.subject = subject }
                            state.tasks[key] = entry
                            state.tasksAreCurrent = true
                        default:
                            break
                        }
                    case "tool_result":
                        guard
                            let id = block["tool_use_id"] as? String,
                            let subject = state.pendingCreates.removeValue(forKey: id),
                            let key = taskNumber(fromResult: block["content"])
                        else { break }
                        if state.tasks[key] == nil { state.order.append(key) }
                        state.tasks[key] = PlanState.TaskEntry(subject: subject, activeForm: nil, status: .pending)
                        state.tasksAreCurrent = true
                    default:
                        break
                    }
                }
                continue
            }

            // Codex rollout: update_plan carries the whole plan each time.
            if (object["type"] as? String)?.contains("function_call") == true,
               object["name"] as? String == "update_plan" {
                state.republished = todoList(from: normalizedInput(object["arguments"]))
                state.tasksAreCurrent = false
            }
        }
    }

    /// Brings a session's checklist up to date in the background, republishing
    /// if it changed. Only one scan per transcript is in flight at a time.
    private func schedulePlanScan(for url: URL) {
        let path = url.path
        guard !planScansInFlight.contains(path) else {
            // Writes landing mid-scan are past the cursor this one captured,
            // so note them and go again rather than waiting for the next poll
            // — the session may fall quiet right after, leaving the checklist
            // permanently a step behind.
            planRescansRequested.insert(path)
            return
        }
        planScansInFlight.insert(path)

        let cursor = planCursors[path] ?? 0
        let state = planStates[path] ?? PlanState()
        Task.detached(priority: .utility) {
            let result = Self.scanPlanChunk(url: url, from: cursor, state: state)
            await MainActor.run {
                let monitor = AgentActivityMonitor.shared
                monitor.planScansInFlight.remove(path)
                let changed = (monitor.planStates[path]?.todos ?? []) != result.state.todos
                monitor.planStates[path] = result.state
                monitor.planCursors[path] = result.cursor
                if changed { monitor.poll() }
                if monitor.planRescansRequested.remove(path) != nil {
                    monitor.schedulePlanScan(for: url)
                }
            }
        }
    }

    /// Task IDs are assigned by the tool rather than the caller, and come back
    /// only in the result prose: "Task #3 created successfully: …".
    nonisolated private static func taskNumber(fromResult content: Any?) -> String? {
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
        } else {
            return nil
        }
        guard let hash = text.firstIndex(of: "#") else { return nil }
        let digits = text[text.index(after: hash)...].prefix(while: \.isNumber)
        return digits.isEmpty ? nil : String(digits)
    }

    /// Task IDs appear as either a string or a number depending on the caller.
    nonisolated private static func taskKey(_ raw: Any?) -> String? {
        if let string = cleanString(raw) { return string }
        if let number = raw as? Int { return String(number) }
        return nil
    }

    nonisolated private static func cleanString(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// Tool inputs arrive already decoded from Claude Code, but as a JSON
    /// string in Codex rollouts.
    nonisolated private static func normalizedInput(_ raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] { return dict }
        if let string = raw as? String,
           let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any] {
            return dict
        }
        return nil
    }

    /// Reads the agent's checklist out of its plan-tracking tool input:
    ///   Claude Code (TodoWrite)  — {todos: [{content, activeForm, status}]}
    ///   Codex (update_plan)      — {plan: [{step, status}]}
    nonisolated private static func todoList(from input: [String: Any]?) -> [AgentTodo] {
        let entries = (input?["todos"] as? [[String: Any]])
            ?? (input?["plan"] as? [[String: Any]])
            ?? []

        return entries.enumerated().compactMap { index, entry in
            let status = AgentTodo.Status(raw: entry["status"] as? String ?? "")
            let base = cleanString(entry["content"]) ?? cleanString(entry["step"])
            // `activeForm` is the present-tense phrasing ("Fixing the parser"),
            // which reads better on the step that's actually running.
            let active = cleanString(entry["activeForm"])
            guard let text = status == .inProgress ? (active ?? base) : (base ?? active) else { return nil }
            return AgentTodo(id: index, text: text, status: status)
        }
    }

    /// Pulls the first question's text and options out of an AskUserQuestion
    /// tool input: `{questions: [{question, options: [{label, description}]}]}`.
    private static func promptPayload(from input: [String: Any]?) -> (question: String?, options: [AgentPromptOption]) {
        guard
            let questions = input?["questions"] as? [[String: Any]],
            let first = questions.first
        else { return (nil, []) }

        let question = first["question"] as? String
        let options = ((first["options"] as? [[String: Any]]) ?? []).enumerated().map { index, option in
            AgentPromptOption(
                index: index,
                label: option["label"] as? String ?? "Option \(index + 1)",
                detail: option["description"] as? String
            )
        }
        return (question, options)
    }

    /// Turns a raw tool call into a human phrase like "Reading main.swift"
    /// or "Running grep -n", matching the checklist styling.
    private static func friendlyLabel(tool: String, input: [String: Any]?) -> String {
        func basename(_ key: String) -> String? {
            (input?[key] as? String).map { ($0 as NSString).lastPathComponent }
        }
        switch tool {
        case "Read":                 return "Reading \(basename("file_path") ?? "a file")"
        case "Write":                return "Writing \(basename("file_path") ?? "a file")"
        case "Edit", "MultiEdit":    return "Editing \(basename("file_path") ?? "a file")"
        case "Bash", "shell":
            let command = (input?["command"] as? String)
                ?? ((input?["command"] as? [String])?.joined(separator: " "))
                ?? ""
            let head = command.split(whereSeparator: { $0 == " " || $0 == "\n" }).prefix(2).joined(separator: " ")
            return head.isEmpty ? "Running a command" : "Running \(head)"
        case "Grep":                 return "Searching \(input?["pattern"] as? String ?? "the code")"
        case "Glob":                 return "Finding files"
        case "Task":                 return "Delegating to a subagent"
        case "WebFetch":             return "Fetching \(URL(string: input?["url"] as? String ?? "")?.host ?? "a page")"
        case "WebSearch":            return "Searching the web"
        case "TodoWrite":            return "Updating the task list"
        case "":                     return "Working"
        default:                     return tool
        }
    }

    private static func truncateForBubble(_ text: String) -> String {
        let limit = 240
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Claude Code encodes the project path into the folder name by
    /// replacing "/" with "-": "-Users-jane-code-myapp" → "myapp".
    private static func claudeProjectName(from encoded: String) -> String {
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        return trimmed.split(separator: "-").last.map(String.init) ?? encoded
    }
}
