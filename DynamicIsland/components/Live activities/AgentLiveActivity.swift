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
/// Codex CLI). Shows a pulsing icon while an agent is working, and the
/// project name (or agent count) plus the current tool on the right.
///
/// Layout mirrors the other inline live activities:
///   [agent icon] ─── [ notch ] ─── [project · tool]
struct AgentLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var monitor = AgentActivityMonitor.shared

    @State private var pulse = false

    private var primary: AgentSession? {
        monitor.workingSessions.first ?? monitor.sessions.first
    }

    private var isWorking: Bool {
        !monitor.workingSessions.isEmpty
    }

    private var rightLabel: String {
        let working = monitor.workingSessions
        if working.count > 1 {
            return "\(working.count) agents"
        }
        guard let session = primary else { return "" }
        if let tool = session.currentTool, !tool.isEmpty {
            return tool
        }
        return session.state == .working ? session.projectName : "Waiting"
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: primary?.kind.iconName ?? "sparkle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isWorking ? Color.orange : Color.gray)
                .opacity(isWorking && pulse ? 0.4 : 1.0)
                .frame(width: 24, alignment: .leading)
                .onAppear { startPulsing() }
                .onChange(of: isWorking) { _, _ in startPulsing() }

            Rectangle()
                .fill(Color.black)
                .frame(width: vm.closedNotchSize.width)

            Text(rightLabel)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(isWorking ? Color.orange : Color.gray)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.3), value: rightLabel)
                .frame(width: 76, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    private func startPulsing() {
        pulse = false
        guard isWorking else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}
