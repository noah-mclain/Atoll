/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import SwiftUI

/// Expanded notch panel for AI coding agents. Sessions page across the tab
/// strip at the top; below it the left column is the agent's live checklist —
/// a filled check for finished steps, an accent play marker on the one
/// running, a hollow circle for what's still queued — and the right column
/// carries what the agent is thinking about right now. When a session is
/// blocked on an AskUserQuestion the choices render as buttons that answer the
/// prompt in its terminal, and the input row at the bottom forwards quick
/// free-form replies the same way.
struct AgentNotchView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var monitor = AgentActivityMonitor.shared
    @State private var selectedID: String?
    @State private var quickReply = ""

    /// Live sessions only, so a finished session leaves the panel with its
    /// pill. Sorted by identity rather than recency: the monitor reorders on
    /// every poll, which would shuffle the tabs under the pointer.
    private var sessions: [AgentSession] {
        monitor.liveSessions.sorted { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.projectName < rhs.projectName
        }
    }

    /// Tabs track a session ID, not a position — sessions come and go while
    /// the panel is open, and an index would silently point at a neighbour.
    private var activeSession: AgentSession? {
        sessions.first { $0.id == selectedID } ?? sessions.first
    }

    var body: some View {
        Group {
            if let session = activeSession {
                content(for: session)
            } else {
                EmptyStateView(message: "No active agents")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        // Fill the panel and pin to the top so the header sits clear of the
        // physical notch; overflow is absorbed by the scrolling columns below
        // rather than pushing content up under the notch.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func content(for session: AgentSession) -> some View {
        VStack(spacing: 6) {
            if sessions.count > 1 {
                sessionTabs(active: session.id)
            }
            header(for: session)

            if session.state == .waitingForInput && !session.pendingOptions.isEmpty {
                promptColumn(for: session)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    checklistColumn(for: session)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    thinkingColumn(for: session)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }

            quickReplyRow(for: session)
        }
    }

    // MARK: - Session tabs

    private func sessionTabs(active: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sessions) { session in
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { selectedID = session.id }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: session.kind.iconName)
                                .font(.system(size: 10, weight: .semibold))
                            Text(session.projectName)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .foregroundStyle(session.id == active ? .white : .white.opacity(0.5))
                        .background(
                            Capsule().fill(session.id == active
                                ? session.kind.accent.opacity(0.35)
                                : Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Header

    private func header(for session: AgentSession) -> some View {
        HStack(spacing: 7) {
            Image(systemName: session.kind.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(session.kind.accent)
                .symbolEffect(.pulse, isActive: session.state == .working)
            Text(session.kind.rawValue)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
            Text("•")
                .foregroundStyle(session.kind.accent)
            Text(session.statusLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(session.kind.accent)
                .lineLimit(1)
            Spacer(minLength: 0)
            if session.projectName != session.kind.rawValue {
                Text(session.projectName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Prompt options

    /// Question plus its selectable answers; picking one presses the matching
    /// number key in the agent's terminal.
    private func promptColumn(for session: AgentSession) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                if let question = session.pendingQuestion, !question.isEmpty {
                    Text(question)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .padding(.bottom, 2)
                }
                ForEach(session.pendingOptions) { option in
                    Button {
                        AgentActivityMonitor.answer(option: option, in: session)
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(option.index + 1)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(session.kind.accent)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if let detail = option.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.5))
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(session.kind.accent.opacity(0.35), lineWidth: 1)
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Left column (scrollable checklist)

    /// The agent's plan when it keeps one, else the trail of tool calls it has
    /// actually run — an agent working without a checklist still gets a
    /// meaningful left column.
    private func checklistColumn(for session: AgentSession) -> some View {
        Group {
            if session.todos.isEmpty {
                toolCallList(for: session)
            } else {
                todoList(for: session)
            }
        }
    }

    private func todoList(for session: AgentSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(session.todos) { todo in
                        todoRow(todo: todo, accent: session.kind.accent)
                            .id(todo.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.todos) { _, todos in
                // Follow the step the agent moved onto.
                guard let running = todos.first(where: { $0.status == .inProgress }) else { return }
                withAnimation(.smooth(duration: 0.25)) {
                    proxy.scrollTo(running.id, anchor: .center)
                }
            }
        }
    }

    private func todoRow(todo: AgentTodo, accent: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: todo.status.iconName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(iconColor(for: todo.status, accent: accent))
                .frame(width: 14)
                .symbolEffect(.pulse, isActive: todo.status == .inProgress)
            // Long labels carousel slowly instead of truncating, like song
            // titles do.
            GeometryReader { geo in
                MarqueeText(
                    .constant(todo.text),
                    font: .system(size: 13, weight: todo.status == .inProgress ? .semibold : .regular),
                    nsFont: .callout,
                    textColor: textColor(for: todo.status),
                    minDuration: 1.5,
                    frameWidth: geo.size.width
                )
            }
            .frame(height: 17)
        }
    }

    private func iconColor(for status: AgentTodo.Status, accent: Color) -> Color {
        switch status {
        case .completed:  return .green
        case .inProgress: return accent
        case .pending:    return .white.opacity(0.3)
        }
    }

    private func textColor(for status: AgentTodo.Status) -> Color {
        switch status {
        case .completed:  return .white.opacity(0.45)
        case .inProgress: return .white
        case .pending:    return .white.opacity(0.65)
        }
    }

    private func toolCallList(for session: AgentSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(session.toolCalls) { call in
                        checklistRow(call: call, accent: session.kind.accent)
                            .id(call.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.currentTool) { _, _ in
                // Keep the in-flight step in view as the agent advances.
                if let current = session.toolCalls.last(where: { !$0.isComplete }) ?? session.toolCalls.last {
                    withAnimation(.smooth(duration: 0.25)) {
                        proxy.scrollTo(current.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func checklistRow(call: AgentToolCall, accent: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: call.isComplete ? "checkmark.circle.fill" : "play.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(call.isComplete ? Color.green : accent)
                .frame(width: 14)
            GeometryReader { geo in
                MarqueeText(
                    .constant(call.label),
                    font: .system(size: 13, weight: call.isComplete ? .regular : .semibold),
                    nsFont: .callout,
                    textColor: call.isComplete ? Color.white.opacity(0.45) : .white,
                    minDuration: 1.5,
                    frameWidth: geo.size.width
                )
            }
            .frame(height: 17)
        }
    }

    // MARK: - Right column (what the agent is doing right now)

    private func thinkingColumn(for session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.state == .working, let tool = session.currentTool, !tool.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: session.kind.iconName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(session.kind.accent)
                        .symbolEffect(.pulse, isActive: true)
                    Text(tool)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(session.kind.accent)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }

            if let text = session.latestText, !text.isEmpty {
                ScrollView(showsIndicators: false) {
                    Text(text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(session.statusLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
    }

    // MARK: - Quick reply

    /// Free-form input forwarded to the agent's terminal (typed + submitted).
    private func quickReplyRow(for session: AgentSession) -> some View {
        HStack(spacing: 8) {
            TextField("Message the agent…", text: $quickReply)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.10))
                .cornerRadius(13)
                .onSubmit { sendQuickReply(to: session) }

            Button { sendQuickReply(to: session) } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(quickReply.trimmingCharacters(in: .whitespaces).isEmpty ? 0.3 : 0.9))
            }
            .buttonStyle(.plain)
            .disabled(quickReply.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func sendQuickReply(to session: AgentSession) {
        let text = quickReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        AgentActivityMonitor.send(text: text, to: session)
        quickReply = ""
    }
}
