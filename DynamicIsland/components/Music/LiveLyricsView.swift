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

/// Apple Music-style live lyrics: the current synced line bold and bright,
/// its neighbors dim and slightly blurred above/below, scrolling as playback
/// advances. Falls back to the single running line when the track only has
/// plain (unsynced) lyrics.
struct LiveLyricsView: View {
    @ObservedObject private var musicManager = MusicManager.shared

    let frameWidth: CGFloat

    private var lines: [LyricLine] { musicManager.syncedLyrics }
    private var index: Int { musicManager.currentLyricIndex }

    /// Synced display needs real timestamps; a lone 0-stamped line is the
    /// plain-lyrics fallback shape.
    private var hasSyncedLines: Bool {
        lines.count > 1 || (lines.first?.timestamp ?? 0) > 0
    }

    var body: some View {
        if hasSyncedLines {
            VStack(alignment: .leading, spacing: 2) {
                neighborLine(at: index - 1)
                currentLine
                neighborLine(at: index + 1)
            }
            .frame(width: frameWidth, alignment: .leading)
            .animation(.smooth(duration: 0.35), value: index)
        } else {
            plainFallback
        }
    }

    @ViewBuilder
    private var currentLine: some View {
        let text = lines.indices.contains(index) ? lines[index].text : ""
        Text(text.isEmpty ? "…" : text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .id("current-\(index)")
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
    }

    @ViewBuilder
    private func neighborLine(at i: Int) -> some View {
        let text = lines.indices.contains(i) ? lines[i].text : ""
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.32))
            .blur(radius: 0.5)
            .lineLimit(1)
            .truncationMode(.tail)
            .id("neighbor-\(i)")
            .transition(.opacity)
    }

    @ViewBuilder
    private var plainFallback: some View {
        let line = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty {
            MarqueeText(
                Binding(get: { musicManager.currentLyrics }, set: { _ in }),
                font: .system(size: 12, weight: .regular),
                nsFont: .headline,
                textColor: .white.opacity(0.7),
                minDuration: 0.35,
                frameWidth: frameWidth
            )
            .id(line)
        }
    }
}
