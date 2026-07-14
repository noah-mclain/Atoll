/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AVFoundation
import SwiftUI

struct NotificationBannerView: View {
    let notification: AtollNotification
    let onDismiss: () -> Void
    let onReply: (String) -> Void

    @State private var replyText: String = ""
    @State private var showReplyField: Bool = false
    @State private var isPlayingVoice: Bool = false
    @State private var voicePlayer: AVAudioPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            if showReplyField, notification.source.supportsQuickReply {
                replyField
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            actionBar
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(notification.source.accentColor).opacity(0.3), lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: showReplyField)
        .onAppear {
            // Messaging apps open straight into the reply field, iOS-style.
            if notification.source.supportsQuickReply {
                showReplyField = true
            }
        }
        .onHover { hovering in
            // Don't let the banner auto-hide out from under an active reply.
            if hovering {
                NotificationObserver.shared.holdCurrentNotification()
            } else {
                NotificationObserver.shared.resumeCurrentNotification()
            }
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(notification.source.accentColor))
                .frame(width: 3, height: 36)

            avatar

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(notification.senderName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let subtitle = notification.subtitle, !subtitle.isEmpty {
                        Text("· \(subtitle)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }

                    Spacer()

                    appIcon
                        .frame(width: 16, height: 16)
                }

                if notification.isVoiceMessage {
                    voiceRow
                } else {
                    Text(notification.body)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(2)
                }
            }
        }
    }

    private var replyField: some View {
        HStack(spacing: 8) {
            TextField("Reply…", text: $replyText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
                .cornerRadius(14)
                .onSubmit { sendReply() }

            Button(action: sendReply) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Color(notification.source.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if notification.source.supportsQuickReply {
                actionButton(label: "Reply", icon: "arrowshape.turn.up.left.fill") {
                    withAnimation(.spring(response: 0.3)) { showReplyField.toggle() }
                }
            }
            actionButton(label: "Open", icon: "arrow.up.right.square") {
                openApp()
                onDismiss()
            }
            Spacer()
            actionButton(label: "", icon: "xmark") { onDismiss() }
        }
    }

    private var avatar: some View {
        Group {
            if let image = notification.senderAvatarImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle()
                        .fill(Color(notification.source.accentColor).opacity(0.3))
                    Text(String(notification.senderName.prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(notification.source.accentColor))
                }
                .frame(width: 36, height: 36)
            }
        }
    }

    private var appIcon: some View {
        Group {
            if let icon = notification.source.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.badge")
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    private var voiceRow: some View {
        HStack(spacing: 8) {
            Button(action: toggleVoicePlayback) {
                Image(systemName: isPlayingVoice ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(notification.source.accentColor))
            }
            .buttonStyle(.plain)

            HStack(spacing: 2) {
                ForEach(0..<20, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(notification.source.accentColor).opacity(0.7))
                        .frame(width: 2, height: waveHeight(for: i))
                }
            }

            Text("Voice message")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private func actionButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundColor(.white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        onReply(text)
        replyText = ""
        withAnimation { showReplyField = false }
        onDismiss()
    }

    private func openApp() {
        if let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == notification.bundleID }) {
            running.activate(options: .activateIgnoringOtherApps)
            return
        }
        if !notification.bundleID.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notification.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    private func toggleVoicePlayback() {
        guard notification.isVoiceMessage else { return }
        if isPlayingVoice {
            voicePlayer?.pause()
            isPlayingVoice = false
            return
        }
        guard let url = notification.voiceMessageURL,
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        voicePlayer = player
        player.play()
        isPlayingVoice = true
    }

    /// Pseudo-random but deterministic waveform pattern (uses index hash so
    /// the bars don't reshuffle on every redraw).
    private func waveHeight(for i: Int) -> CGFloat {
        let seed = (i &* 2654435761) & 0xFFFF
        let normalized = CGFloat(seed) / CGFloat(0xFFFF)
        return 4 + normalized * 12
    }
}
