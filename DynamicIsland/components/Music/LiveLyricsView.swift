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

/// Full lyrics for the open notch, taking the calendar's slot so lines have
/// the width to wrap instead of truncating beside the album art. Reads like
/// Apple Music: the whole song is there, the current line bright and bold,
/// everything else dimmed, scrolling itself as playback advances.
struct LyricsPanel: View {
    @ObservedObject private var musicManager = MusicManager.shared

    private var lines: [LyricLine] { musicManager.syncedLyrics }
    private var index: Int { musicManager.currentLyricIndex }

    /// Synced display needs real timestamps; a lone 0-stamped line is the
    /// plain-lyrics fallback shape.
    private var hasSyncedLines: Bool {
        lines.count > 1 || (lines.first?.timestamp ?? 0) > 0
    }

    private var plainText: String {
        musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if hasSyncedLines {
                syncedLines
            } else if !plainText.isEmpty {
                plainBlock
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var syncedLines: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { position, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: position == index ? 14 : 12,
                                          weight: position == index ? .bold : .medium))
                            .foregroundStyle(position == index ? .white : .white.opacity(0.3))
                            // Wrap rather than truncate — the whole point of
                            // giving lyrics the wider slot.
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(position)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: index) { _, current in
                guard lines.indices.contains(current) else { return }
                withAnimation(.smooth(duration: 0.35)) {
                    proxy.scrollTo(current, anchor: .center)
                }
            }
            .onAppear {
                guard lines.indices.contains(index) else { return }
                proxy.scrollTo(index, anchor: .center)
            }
        }
        .animation(.smooth(duration: 0.3), value: index)
    }

    private var plainBlock: some View {
        ScrollView(showsIndicators: false) {
            Text(plainText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.25))
            Text("No lyrics for this track")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
