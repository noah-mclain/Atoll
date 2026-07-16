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

/// Quiet closed-notch peek for a notification that isn't set to expand the
/// island. Mirrors the other inline live activities:
///   [app icon] ─── [ notch ] ─── [sender]
/// Tapping it opens the notch straight to the Alerts scrollback.
struct NotificationLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var observer = NotificationObserver.shared
    @ObservedObject private var coordinator = DynamicIslandViewCoordinator.shared

    let notification: AtollNotification

    var body: some View {
        HStack(spacing: 0) {
            appIcon
                .frame(width: 24, height: 24)
                .frame(width: 30, alignment: .leading)

            Rectangle()
                .fill(Color.black)
                .frame(width: vm.closedNotchSize.width)

            Text(notification.senderName)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        .onTapGesture {
            coordinator.currentView = .notifications
            // Open this window's own view model — the delegate's bare `vm`
            // drives nothing when the island shows on every display.
            vm.open()
        }
    }

    private var appIcon: some View {
        Group {
            if let icon = notification.appIconImage {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "bell.fill").foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}
