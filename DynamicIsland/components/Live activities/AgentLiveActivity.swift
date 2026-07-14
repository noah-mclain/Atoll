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

/// Closed-notch live activity for running AI coding agents (Claude Code,
/// Codex CLI). It only appears while an agent is actively working, waiting on
/// a choice, or freshly finished — an idle session doesn't linger.
///
/// Layout mirrors the other inline live activities:
///   [agent icon] ─── [ notch ] ─── [status · tool]
struct AgentLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var monitor = AgentActivityMonitor.shared
    @ObservedObject private var coordinator = DynamicIslandViewCoordinator.shared

    @State private var pulse = false

    /// Prefer the most actionable session: working, then waiting, then done.
    private var primary: AgentSession? {
        let live = monitor.liveSessions
        return live.first(where: { $0.state == .working })
            ?? live.first(where: { $0.state == .waitingForInput })
            ?? live.first
    }

    private var isWorking: Bool { primary?.state == .working }

    private var accent: Color {
        guard let primary else { return .gray }
        switch primary.state {
        case .working:        return primary.kind.accent
        case .waitingForInput: return .yellow
        case .done:           return .green
        }
    }

    private var rightLabel: String {
        let working = monitor.workingSessions
        if working.count > 1 { return "\(working.count) agents" }
        guard let session = primary else { return "" }
        switch session.state {
        case .working:
            if let tool = session.currentTool, !tool.isEmpty { return tool }
            return session.projectName
        case .waitingForInput: return "Your input"
        case .done:            return "Finished"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: primary?.kind.iconName ?? "sparkle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .opacity(isWorking && pulse ? 0.4 : 1.0)
                .frame(width: 24, alignment: .leading)
                .onAppear { startPulsing() }
                .onChange(of: isWorking) { _, _ in startPulsing() }

            Rectangle()
                .fill(Color.black)
                .frame(width: vm.closedNotchSize.width)

            Text(rightLabel)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.3), value: rightLabel)
                .frame(width: 76, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        .onTapGesture {
            // Waiting on a choice → jump straight to the terminal to answer;
            // otherwise open the expanded agent panel.
            if primary?.state == .waitingForInput {
                AgentActivityMonitor.focusAgentTerminal()
            } else {
                coordinator.currentView = .agent
                AppDelegate.shared?.vm.open()
            }
        }
    }

    private func startPulsing() {
        pulse = false
        guard isWorking else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}
