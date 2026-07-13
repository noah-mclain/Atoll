/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import SwiftUI

struct CallBannerView: View {
    let call: AtollCall
    let onAccept: () -> Void
    let onDecline: () -> Void

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 14) {
            avatarColumn

            VStack(alignment: .leading, spacing: 3) {
                Text(call.source.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(call.source.subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: sourceIcon)
                        .font(.system(size: 10))
                        .foregroundColor(Color(call.source.accentColor))
                    Text("Incoming call")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            Spacer()

            VStack(spacing: 8) {
                callButton(icon: acceptIcon, color: .systemGreen, action: onAccept)
                callButton(icon: "phone.down.fill", color: .systemRed, action: onDecline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color(call.source.accentColor).opacity(0.35), lineWidth: 1)
                )
        )
    }

    // MARK: - Subviews

    private var avatarColumn: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color(call.source.accentColor).opacity(0.4 - Double(i) * 0.1))
                    .frame(width: CGFloat(44 + i * 12), height: CGFloat(44 + i * 12))
                    .scaleEffect(pulsing ? 1.15 : 1.0)
                    .opacity(pulsing ? 0.0 : 1.0)
                    .animation(
                        .easeOut(duration: 1.4)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.4),
                        value: pulsing
                    )
            }
            callerAvatar
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(call.source.accentColor), lineWidth: 2))
        }
        .frame(width: 68, height: 68)
        .onAppear { pulsing = true }
    }

    private var callerAvatar: some View {
        Group {
            if let image = call.source.callerImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(call.source.accentColor).opacity(0.25)
                    Text(String(call.source.displayName.prefix(1)).uppercased())
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Color(call.source.accentColor))
                }
            }
        }
    }

    private var acceptIcon: String {
        switch call.source {
        case .facetime(_, _, let isVideo): return isVideo ? "video.fill" : "phone.fill"
        case .phone:                       return "phone.fill"
        case .discord:                     return "arrow.up.right"
        case .voip:                        return "phone.fill"
        }
    }

    private var sourceIcon: String {
        switch call.source {
        case .facetime: return "video.fill"
        case .phone:    return "iphone"
        case .discord:  return "waveform"
        case .voip:     return "phone.connection"
        }
    }

    private func callButton(icon: String, color: NSColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(color))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .shadow(color: Color(color).opacity(0.5), radius: 6, y: 2)
    }
}
