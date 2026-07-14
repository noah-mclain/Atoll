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

/// Expanded notch panel for AI coding agents. Left column is the session
/// header plus a checklist of recent tool calls (green check when settled,
/// an accent triangle for the one in flight); the right column is a bubble
/// with the agent's latest prose. Multiple concurrent sessions page across
/// with the dots at the bottom.
struct AgentNotchView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var monitor = AgentActivityMonitor.shared
    @State private var selection = 0

    private var sessions: [AgentSession] { monitor.sessions }

    var body: some View {
        Group {
            if sessions.isEmpty {
                EmptyStateView(message: "No active agents")
            } else {
                content
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onChange(of: sessions.count) { _, count in
            if selection >= count { selection = max(0, count - 1) }
        }
    }

    private var content: some View {
        let index = min(selection, sessions.count - 1)
        let session = sessions[index]
        return VStack(spacing: 6) {
            header(for: session)

            HStack(alignment: .top, spacing: 14) {
                checklistColumn(for: session)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let text = session.latestText, !text.isEmpty {
                    detailBubble(text: text)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if sessions.count > 1 {
                pageDots(count: sessions.count, active: index)
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

    // MARK: - Left column (scrollable checklist)

    private func checklistColumn(for session: AgentSession) -> some View {
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
            Image(systemName: call.isComplete ? "checkmark" : "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(call.isComplete ? Color.green : accent)
                .frame(width: 14)
            Text(call.label)
                .font(.system(size: 13, weight: call.isComplete ? .regular : .semibold))
                .foregroundStyle(call.isComplete ? Color.white.opacity(0.7) : .white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Right column

    private func detailBubble(text: String) -> some View {
        ScrollView(showsIndicators: false) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
    }

    private func pageDots(count: Int, active: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { dot in
                Capsule()
                    .fill(dot == active ? Color.white : Color.white.opacity(0.3))
                    .frame(width: dot == active ? 14 : 5, height: 5)
                    .onTapGesture { withAnimation(.smooth(duration: 0.2)) { selection = dot } }
            }
        }
    }
}
