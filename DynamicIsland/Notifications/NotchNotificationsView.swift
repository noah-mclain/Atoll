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

/// Notification scrollback — the notch's own "notification center". Lists the
/// recently received notifications so one that auto-hid can still be read and,
/// for messaging apps, replied to inline.
struct NotchNotificationsView: View {
    @ObservedObject private var observer = NotificationObserver.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if observer.history.isEmpty {
                EmptyStateView(message: "No recent notifications")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(observer.history) { notification in
                            NotificationHistoryRow(notification: notification)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            Text("Notifications")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            if !observer.history.isEmpty {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { observer.clearHistory() }
                } label: {
                    Text("Clear")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct NotificationHistoryRow: View {
    let notification: AtollNotification

    @State private var replyText = ""
    @State private var isReplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(notification.senderName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(notification.appName)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(notification.timestamp, style: .relative)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                            .fixedSize()
                    }
                    Text(notification.body)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }

            if isReplying {
                replyField
            }

            if notification.source.supportsQuickReply {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { isReplying.toggle() }
                } label: {
                    Label(isReplying ? "Cancel" : "Reply", systemImage: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var replyField: some View {
        HStack(spacing: 8) {
            TextField("Reply…", text: $replyText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
                .cornerRadius(14)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(notification.source.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var avatar: some View {
        Group {
            if let image = notification.senderAvatarImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color(notification.source.accentColor).opacity(0.3))
                    Text(String(notification.senderName.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(notification.source.accentColor))
                }
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        // Badge with the originating app's real icon (WhatsApp, Discord,
        // Messages, …) so the source is obvious at a glance.
        .overlay(alignment: .bottomTrailing) { appIconBadge }
    }

    @ViewBuilder
    private var appIconBadge: some View {
        if let icon = notification.appIconImage {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
                .background(
                    Circle()
                        .fill(.black)
                        .frame(width: 17, height: 17)
                )
                .offset(x: 3, y: 3)
        }
    }

    private func send() {
        let text = replyText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        QuickReplyDispatcher.send(reply: text, for: notification)
        replyText = ""
        withAnimation(.smooth(duration: 0.2)) { isReplying = false }
    }
}
