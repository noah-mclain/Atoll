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

struct AgentSession: Identifiable, Equatable {
    enum Kind: String {
        case claudeCode = "Claude Code"
        case codex = "Codex"

        var iconName: String {
            switch self {
            case .claudeCode: return "sparkle"
            case .codex:      return "terminal"
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
    private var lastKnownTools: [String: String] = [:]

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
            lastKnownTools.removeValue(forKey: logURL.path)
            return nil
        }

        let state: AgentSession.ActivityState = age < Self.workingThreshold ? .working : .waiting

        var tool: String? = lastKnownTools[logURL.path]
        let size = UInt64(values.fileSize ?? 0)
        if state == .working, lastKnownSizes[logURL.path] != size {
            lastKnownSizes[logURL.path] = size
            if let parsed = Self.currentToolName(in: logURL) {
                tool = parsed
                lastKnownTools[logURL.path] = parsed
            }
        }

        return AgentSession(
            id: logURL.path,
            kind: kind,
            projectName: projectName,
            state: state,
            lastActivity: modified,
            currentTool: state == .working ? tool : nil
        )
    }

    // MARK: - Log parsing

    /// Reads the tail of the JSONL transcript and returns the most recent
    /// tool_use name, if the last assistant event was a tool call.
    private static func currentToolName(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let tailLength: UInt64 = 16_384
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > tailLength ? fileSize - tailLength : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() {
            guard
                let lineData = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // Claude Code shape: {"type":"assistant","message":{"content":[{"type":"tool_use","name":…}]}}
            if let message = object["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content.reversed() where (block["type"] as? String) == "tool_use" {
                    return block["name"] as? String
                }
            }
            // Codex shape: {"type":"function_call","name":…} or nested payloads.
            if (object["type"] as? String)?.contains("function_call") == true {
                return object["name"] as? String
            }
        }
        return nil
    }

    /// Claude Code encodes the project path into the folder name by
    /// replacing "/" with "-": "-Users-jane-code-myapp" → "myapp".
    private static func claudeProjectName(from encoded: String) -> String {
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        return trimmed.split(separator: "-").last.map(String.init) ?? encoded
    }
}
