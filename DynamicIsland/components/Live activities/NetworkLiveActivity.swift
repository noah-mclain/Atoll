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

/// Closed-notch HUD for connectivity transitions, plus a persistent state
/// while the Mac is fully offline.
///
/// Layout mirrors the other inline live activities:
///   [status icon] ─── [ notch ] ─── [network name]
struct NetworkLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var networkManager = NetworkStatusManager.shared

    private var tint: Color {
        networkManager.isOffline ? .red : .green
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: networkManager.kind.iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, alignment: .leading)

            Rectangle()
                .fill(Color.black)
                .frame(width: vm.closedNotchSize.width)

            Text(networkManager.statusLabel)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(width: 76, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }
}
