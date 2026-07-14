/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Combine
import Foundation
import SwiftUI

/// A single tool invocation surfaced in the agent checklist.
struct AgentToolCall: Identifiable, Equatable {
    let id: String       // the tool_use id, or a synthesized fallback
    let label: String    // e.g. "Reading nz_2.png", "Running grep -n"
    var isComplete: Bool // has a matching tool_result arrived?
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
        /// Session exists but has gone quiet — likely waiting for the user.
        case waiting
    }

    let id: String              // absolute path of the session log
    let kind: Kind
    let projectName: String
    var state: ActivityState
    var lastActivity: Date
    var currentTool: String?
    /// Recent tool calls, oldest first; the last is current while working.
    var toolCalls: [AgentToolCall] = []
    /// Latest assistant prose, shown in the detail bubble.
    var latestText: String?
    /// Human-friendly session summary, if the transcript carries one.
    var title: String?

    /// Header status line, e.g. "Thinking", "Working on your task".
    var statusLabel: String {
        switch state {
        case .waiting:
            return "Waiting for your input"
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
    var hasActivity: Bool { !sessions.isEmpty }

    private static let workingThreshold: TimeInterval = 20
    private static let sessionTimeout: TimeInterval = 15 * 60
    private static let pollInterval: TimeInterval = 2

    private var pollTimer: Timer?
    private var lastKnownSizes: [String: UInt64] = [:]
    private var lastKnownParses: [String: ParsedTranscript] = [:]

    /// The slice of a transcript we surface in the UI.
    private struct ParsedTranscript: Equatable {
        var toolCalls: [AgentToolCall] = []
        var latestText: String?
        var title: String?
        var currentTool: String?
    }

    /// How many trailing tool calls to keep for the checklist.
    private static let checklistDepth = 5

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
        if updated != sessions {
            sessions = updated
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
            return nil
        }

        let state: AgentSession.ActivityState = age < Self.workingThreshold ? .working : .waiting

        // Re-parse only when the file actually grew — parsing is the only
        // expensive step, so cache the last result per path.
        var parsed = lastKnownParses[logURL.path] ?? ParsedTranscript()
        let size = UInt64(values.fileSize ?? 0)
        if lastKnownSizes[logURL.path] != size {
            lastKnownSizes[logURL.path] = size
            parsed = Self.parseTranscript(in: logURL, kind: kind)
            lastKnownParses[logURL.path] = parsed
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
            latestText: parsed.latestText,
            title: parsed.title
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
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return ParsedTranscript() }

        var ordered: [(id: String, label: String)] = []
        var resultIDs: Set<String> = []
        var latestText: String?
        var title: String?
        var syntheticIndex = 0

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
                        ordered.append((id, friendlyLabel(tool: block["name"] as? String ?? "", input: block["input"] as? [String: Any])))
                    case "tool_result":
                        if let id = block["tool_use_id"] as? String { resultIDs.insert(id) }
                    case "text":
                        if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                            latestText = t
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
            case let type? where type.contains("function_call"):
                let id = object["call_id"] as? String ?? "auto-\(syntheticIndex)"
                syntheticIndex += 1
                ordered.append((id, friendlyLabel(tool: object["name"] as? String ?? "", input: object["arguments"] as? [String: Any])))
            case "message":
                if let content = object["content"] as? [[String: Any]] {
                    for block in content where (block["type"] as? String)?.contains("text") == true {
                        if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                            latestText = t
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

        return ParsedTranscript(
            toolCalls: recent,
            latestText: latestText.map(truncateForBubble),
            title: title,
            currentTool: currentTool
        )
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
